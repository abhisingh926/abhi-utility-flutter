package com.abhi.abhi_utility

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.graphics.Bitmap
import android.graphics.Canvas
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Calendar

/**
 * App lock rules, stored on the phone.
 * SharedPreferences "app_lock", key "rules": {"package": {"mode": ..., "minutes": N}}
 *
 * Modes:
 *  - "block":  always locked
 *  - "daily":  locked once [minutes] are used today; unlocks at midnight
 *  - "hourly": locked once [minutes] are used in the current clock hour; unlocks at the next hour
 */
object AppLock {
    private const val PREFS = "app_lock"
    private const val KEY_RULES = "rules"

    data class Rule(val mode: String, val minutes: Int)

    data class Status(
        val locked: Boolean,
        /** Seconds used in the current window (today or this hour). */
        val usedSeconds: Int,
        /** Allowed seconds in this window (limit + extra time given with the password). */
        val limitSeconds: Int,
        /** Seconds left before it locks; 0 when locked. */
        val remainingSeconds: Int,
        /** When it unlocks (epoch ms), or null if it never unlocks by itself. */
        val unlockAt: Long?,
    )

    // ---- Password -------------------------------------------------------------------

    private const val KEY_PIN_HASH = "pin_hash"
    private const val KEY_PIN_SALT = "pin_salt"
    private const val KEY_BONUS = "bonus"

    fun hasPin(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).contains(KEY_PIN_HASH)

    fun setPin(context: Context, pin: String) {
        val salt = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val saltHex = salt.joinToString("") { "%02x".format(it) }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_PIN_SALT, saltHex)
            .putString(KEY_PIN_HASH, hash(saltHex, pin))
            .apply()
    }

    fun checkPin(context: Context, pin: String): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val salt = prefs.getString(KEY_PIN_SALT, null) ?: return false
        val expected = prefs.getString(KEY_PIN_HASH, null) ?: return false
        return MessageDigest.isEqual(hash(salt, pin).toByteArray(), expected.toByteArray())
    }

    private fun hash(salt: String, pin: String): String =
        MessageDigest.getInstance("SHA-256").digest("$salt:$pin".toByteArray())
            .joinToString("") { "%02x".format(it) }

    // ---- Extra time given with the password -------------------------------------------

    /** The limit window a rule counts in: today for daily/block, this clock hour for hourly. */
    private fun windowKey(rule: Rule): String =
        if (rule.mode == "hourly") ReelStats.dayKey() + "-" + Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        else ReelStats.dayKey()

    private fun bonusSeconds(context: Context, pkg: String, rule: Rule): Int {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_BONUS, "{}")!!
        return JSONObject(raw).optInt("$pkg|${windowKey(rule)}", 0)
    }

    /** Gives [pkg] [seconds] more time in its current window. */
    fun addBonus(context: Context, pkg: String, rule: Rule, seconds: Int) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val json = JSONObject(prefs.getString(KEY_BONUS, "{}")!!)
        val key = "$pkg|${windowKey(rule)}"
        // Drop extra time from past days.
        val today = ReelStats.dayKey()
        json.keys().asSequence().toList().filter { !it.substringAfter('|').startsWith(today) }
            .forEach { json.remove(it) }
        json.put(key, json.optInt(key, 0) + seconds)
        prefs.edit().putString(KEY_BONUS, json.toString()).apply()
    }

    fun rules(context: Context): Map<String, Rule> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_RULES, "{}")!!
        val json = JSONObject(raw)
        return json.keys().asSequence().associateWith {
            val r = json.getJSONObject(it)
            Rule(r.optString("mode", "block"), r.optInt("minutes", 0))
        }
    }

    fun setRule(context: Context, pkg: String, rule: Rule?) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val json = JSONObject(prefs.getString(KEY_RULES, "{}")!!)
        if (rule == null) json.remove(pkg)
        else json.put(pkg, JSONObject().put("mode", rule.mode).put("minutes", rule.minutes))
        prefs.edit().putString(KEY_RULES, json.toString()).apply()
    }

    /**
     * Lock status of [pkg]. [unsavedSeconds] is time from the current session that
     * the service hasn't written to storage yet.
     */
    fun status(context: Context, pkg: String, rule: Rule, unsavedSeconds: Int = 0): Status {
        val bonus = bonusSeconds(context, pkg, rule)
        val used = unsavedSeconds + when (rule.mode) {
            "hourly" -> ReelStats.hourSeconds(context, pkg)
            // "block": time behind the lock screen isn't saved, so today's time is
            // only the extra time used.
            else -> ReelStats.todaySeconds(context)[pkg] ?: 0
        }
        val limit = (if (rule.mode == "block") 0 else rule.minutes * 60) + bonus
        val left = limit - used
        val unlockAt = when {
            left > 0 -> null
            rule.mode == "daily" -> nextMidnight()
            rule.mode == "hourly" -> nextHour()
            else -> null
        }
        return Status(left <= 0, used, limit, maxOf(left, 0), unlockAt)
    }

    private fun nextMidnight(): Long = Calendar.getInstance().apply {
        add(Calendar.DAY_OF_YEAR, 1)
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    private fun nextHour(): Long = Calendar.getInstance().apply {
        add(Calendar.HOUR_OF_DAY, 1)
        set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    fun appLabel(context: Context, pkg: String): String = try {
        val pm = context.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (_: PackageManager.NameNotFoundException) {
        ReelApps.NAMES[pkg] ?: pkg
    }

    /** App icon as PNG bytes, or null. */
    fun appIcon(context: Context, pkg: String, sizePx: Int = 96): ByteArray? = try {
        val d = context.packageManager.getApplicationIcon(pkg)
        val bmp = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, sizePx, sizePx)
        d.draw(Canvas(bmp))
        ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    } catch (_: Exception) {
        null
    }

    /** Social media / short-video / chat apps (many don't declare the Social category). */
    private val SOCIAL = ReelApps.NAMES.keys + setOf(
        "com.twitter.android",
        "com.instagram.barcelona", // Threads
        "com.instagram.lite",
        "com.reddit.frontpage",
        "com.pinterest",
        "com.linkedin.android",
        "com.tumblr",
        "com.whatsapp",
        "com.whatsapp.w4b",
        "org.telegram.messenger",
        "org.thunderdog.challegram",
        "com.facebook.orca", // Messenger
        "com.discord",
        "com.bereal.ft",
        "com.quora.android",
        "com.koo.app",
        "com.google.android.apps.youtube.music",
        "com.josh.app",
    )

    data class App(val pkg: String, val label: String, val category: String, val system: Boolean)

    /**
     * Apps that appear in the launcher (except this one), sorted by name.
     * category: "social", "game" or "other"; system: pre-installed (built-in) app.
     */
    fun launchableApps(context: Context): List<App> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(intent, 0)
            .map { it.activityInfo.applicationInfo }
            .distinctBy { it.packageName }
            .filter { it.packageName != context.packageName }
            .map { info ->
                val declared = if (Build.VERSION.SDK_INT >= 26) info.category else -1
                val category = when {
                    info.packageName in SOCIAL || declared == ApplicationInfo.CATEGORY_SOCIAL -> "social"
                    declared == ApplicationInfo.CATEGORY_GAME ||
                        (info.flags and ApplicationInfo.FLAG_IS_GAME) != 0 -> "game"
                    else -> "other"
                }
                val system = (info.flags and (ApplicationInfo.FLAG_SYSTEM or
                    ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0
                App(info.packageName, pm.getApplicationLabel(info).toString(), category, system)
            }
            .sortedBy { it.label.lowercase() }
    }
}
