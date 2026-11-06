package com.abhi.abhi_utility

import android.content.Context
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** Short-video apps whose reels are counted (package name -> display name). */
object ReelApps {
    val NAMES = linkedMapOf(
        "com.instagram.android" to "Instagram",
        "com.google.android.youtube" to "YouTube",
        "com.facebook.katana" to "Facebook",
        "com.facebook.lite" to "Facebook Lite",
        "com.snapchat.android" to "Snapchat",
        "in.mohalla.video" to "Moj",
        "in.mohalla.sharechat" to "ShareChat",
        "com.eterno.shortvideos" to "Josh",
        "com.next.innovation.takatak" to "MX TakaTak",
        "io.chingari.app" to "Chingari",
        "com.zhiliaoapp.musically" to "TikTok",
        "com.ss.android.ugc.trill" to "TikTok",
        "com.roposo.android" to "Roposo",
    )
}

/**
 * Daily reel counts and time spent, stored on the phone only.
 * SharedPreferences "reel_stats":
 *   "yyyy-MM-dd"   -> JSON {"package": reel count}
 *   "t:yyyy-MM-dd" -> JSON {"package": seconds spent in the app}
 */
object ReelStats {
    private const val PREFS = "reel_stats"
    private const val KEY_LAST_DAY = "_last_day"
    private const val KEY_OVERLAY = "_overlay_enabled"
    private const val TIME_PREFIX = "t:"
    private const val KEEP_DAYS = 90

    fun isOverlayEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_OVERLAY, true)

    fun setOverlayEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_OVERLAY, enabled).apply()
    }

    /** Adds [seconds] of time spent in [pkg] today and in the current clock hour. */
    @Synchronized
    fun addSeconds(context: Context, pkg: String, seconds: Int) {
        if (seconds <= 0) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val edit = prefs.edit()
        for (key in listOf(TIME_PREFIX + dayKey(), hourKey())) {
            val json = JSONObject(prefs.getString(key, "{}")!!)
            json.put(pkg, json.optInt(pkg, 0) + seconds)
            edit.putString(key, json.toString())
        }
        // Only the current hour is needed (for hourly limits).
        prefs.all.keys.filter { it.startsWith(HOUR_PREFIX) && it != hourKey() }.forEach { edit.remove(it) }
        edit.apply()
    }

    /** Seconds spent in [pkg] in the current clock hour (e.g. 12:00–12:59). */
    fun hourSeconds(context: Context, pkg: String): Int {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(hourKey(), null)
        return toMap(raw)[pkg] ?: 0
    }

    private const val HOUR_PREFIX = "h:"

    private fun hourKey(): String =
        HOUR_PREFIX + SimpleDateFormat("yyyy-MM-dd-HH", Locale.US).format(Date())

    fun todayCounts(context: Context): Map<String, Int> =
        toMap(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(dayKey(), null))

    fun todaySeconds(context: Context): Map<String, Int> =
        toMap(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(TIME_PREFIX + dayKey(), null))

    /** Seconds per app for the last [days] days, newest first. */
    fun lastDaysTime(context: Context, days: Int): Map<String, Map<String, Int>> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val cal = Calendar.getInstance()
        val out = linkedMapOf<String, Map<String, Int>>()
        repeat(days) {
            val key = dayKey(cal.time)
            out[key] = toMap(prefs.getString(TIME_PREFIX + key, null))
            cal.add(Calendar.DAY_OF_YEAR, -1)
        }
        return out
    }

    fun dayKey(date: Date = Date()): String =
        SimpleDateFormat("yyyy-MM-dd", Locale.US).format(date)

    /**
     * Adds one reel for [pkg] today. Returns the previous day's counts when this
     * is the first reel of a new day (used for the daily report notification).
     */
    @Synchronized
    fun increment(context: Context, pkg: String): Pair<String, Map<String, Int>>? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val today = dayKey()
        val json = JSONObject(prefs.getString(today, "{}")!!)
        json.put(pkg, json.optInt(pkg, 0) + 1)

        val lastDay = prefs.getString(KEY_LAST_DAY, null)
        val edit = prefs.edit().putString(today, json.toString()).putString(KEY_LAST_DAY, today)
        pruneOld(prefs.all.keys, edit)
        edit.apply()

        if (lastDay != null && lastDay != today) {
            val prev = toMap(prefs.getString(lastDay, null))
            if (prev.isNotEmpty()) return lastDay to prev
        }
        return null
    }

    /** Counts for the last [days] days, newest first: {"yyyy-MM-dd": {"package": count}}. */
    fun lastDays(context: Context, days: Int): Map<String, Map<String, Int>> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val cal = Calendar.getInstance()
        val out = linkedMapOf<String, Map<String, Int>>()
        repeat(days) {
            val key = dayKey(cal.time)
            out[key] = toMap(prefs.getString(key, null))
            cal.add(Calendar.DAY_OF_YEAR, -1)
        }
        return out
    }

    private fun toMap(raw: String?): Map<String, Int> {
        if (raw == null) return emptyMap()
        val json = JSONObject(raw)
        return json.keys().asSequence().associateWith { json.optInt(it, 0) }
    }

    private fun pruneOld(keys: Set<String>, edit: android.content.SharedPreferences.Editor) {
        val cal = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -KEEP_DAYS) }
        val cutoff = dayKey(cal.time)
        keys.filter { !it.startsWith("_") && !it.startsWith(HOUR_PREFIX) && it.removePrefix(TIME_PREFIX) < cutoff }
            .forEach { edit.remove(it) }
    }
}
