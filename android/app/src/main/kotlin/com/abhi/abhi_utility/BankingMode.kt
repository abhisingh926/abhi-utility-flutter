package com.abhi.abhi_utility

import android.Manifest
import android.app.AppOpsManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.provider.Settings
import android.util.Log

/**
 * Banking apps (Paytm, PhonePe, bank apps…) refuse to work while an accessibility service
 * they don't trust is on. So while one of them is open, the reel counter switches itself off.
 *
 * Which apps are banking apps: a built-in list, apps whose name looks like a bank / payment
 * app, apps that showed an "accessibility" warning (learned), plus the user's own choices.
 *
 * Switching back on:
 * - With WRITE_SECURE_SETTINGS (only adb can grant it:
 *   `pm grant com.abhi.abhi_utility android.permission.WRITE_SECURE_SETTINGS`) the counter
 *   switches itself off and on again by itself ([BankingPauseService]).
 * - Without it (normal users) the counter can only switch itself off (disableSelf), and a
 *   notification lets the user turn it back on in one tap.
 */
object BankingMode {
    private const val TAG = "BankingMode"
    private const val PREFS = "banking_mode"
    private const val KEY_AUTO = "auto"
    private const val KEY_EXTRA = "extra"       // added by the user or learned
    private const val KEY_EXCLUDED = "excluded" // detected, but unticked by the user
    private const val CHANNEL = "banking_pause"
    const val REENABLE_NOTIFICATION_ID = 4712

    /** Known banking / UPI / wallet / card / investing apps. */
    val BANK_PACKAGES = setOf(
        // UPI and wallets
        "net.one97.paytm", "com.paytm.business", "com.paytmmoney",
        "com.phonepe.app", "com.phonepe.app.business",
        "com.google.android.apps.nbu.paisa.user", "com.google.android.apps.nbu.paisa.merchant",
        "in.org.npci.upiapp", "com.mobikwik_new", "com.freecharge.android", "com.dreamplug.androidapp",
        "money.super.payments", "com.jiofinance",
        // Banks
        "com.sbi.lotusintouch", "com.sbi.SBIFreedomPlus", "com.sbi.upi", "com.sbi.yonobusiness",
        "com.snapwork.hdfc", "com.hdfcbank.payzapp", "com.hdfc.retail.banking",
        "com.csam.icici.bank.imobile", "com.icicibank.pockets", "com.icici.ileap",
        "com.axis.mobile", "com.axisbank.openbank",
        "com.msf.kbank.mobile", "com.kotak811mobilebankingapp.instantsavingsupiscanandpayrecharge",
        "com.idfcfirstbank.optimus", "com.yesbank", "com.indusind.indie",
        "com.bankofbaroda.mconnect", "com.bob.bobworld",
        "com.infrasofttech.indianBank", "com.canarabank.mobility", "com.unionbank.ecommerce.mobile.android",
        "com.pnb.pnbone", "com.lcode.boimobile", "com.mgs.centralbank", "com.iob.ebanking",
        "com.fss.ucobank", "com.federalbank.fedmobile", "com.rblbank.mobank", "com.aubank.aum",
        "com.dbs.in.digitalbank", "com.equitas.mobile", "com.fi.money", "com.jupiter.money",
        // Cards, loans, insurance, investing
        "com.ge.capital.konysbiapp", "com.hdfcclife.activities", "com.bajajfinserv.app",
        "com.onecard.app", "com.slice", "com.uni.cards",
        "com.zerodha.kite3", "com.nextbillion.groww", "com.upstox.pro", "com.angelbroking.angelone",
        "com.msf.angelmobile", "com.dhan.live", "com.cred.mint", "com.policybazaar",
    )

    /** Words in an app's package or name that mean it handles money. */
    private val WORDS = setOf(
        "bank", "banking", "pay", "upi", "wallet", "finance", "finserv", "money", "loan", "loans",
        "credit", "card", "cards", "invest", "investing", "trading", "broking", "stocks", "demat",
        "mutual", "insurance", "securities", "lending", "nbfc",
    )
    /** Parts of a package name that mean a bank or payment app even inside a word (e.g. idfcfirstbank, payzapp). */
    private val PACKAGE_PARTS = listOf("bank", "pay", "wallet", "money", "finserv")

    private val guessCache = HashMap<String, Boolean>()

    /** Is [pkg] an app that should pause the counter? */
    fun isBankApp(ctx: Context, pkg: String?): Boolean {
        if (pkg == null || pkg == ctx.packageName) return false
        val p = prefs(ctx)
        if (pkg in p.getStringSet(KEY_EXCLUDED, emptySet())!!) return false
        if (pkg in p.getStringSet(KEY_EXTRA, emptySet())!!) return true
        return isDetected(ctx, pkg)
    }

    /** Built-in list or name guess (ignores the user's choices). */
    fun isDetected(ctx: Context, pkg: String): Boolean =
        pkg in BANK_PACKAGES || guessCache.getOrPut(pkg) { looksLikeBank(ctx, pkg) }

    private fun looksLikeBank(ctx: Context, pkg: String): Boolean {
        val pkgLower = pkg.lowercase()
        if (pkgLower.startsWith("com.android.") || pkgLower.startsWith("com.google.android.gms")) return false
        val segments = pkgLower.split('.', '_')
        if (segments.any { s -> s in WORDS || PACKAGE_PARTS.any { s.contains(it) && !s.contains("display") && !s.contains("play") } }) {
            return true
        }
        val label = try {
            val pm = ctx.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString().lowercase()
        } catch (_: Exception) {
            return false
        }
        return label.split(Regex("[^a-z]+")).any { it in WORDS }
    }

    /** Remembers an app that showed an accessibility warning. */
    fun learn(ctx: Context, pkg: String) {
        val p = prefs(ctx)
        if (pkg in p.getStringSet(KEY_EXCLUDED, emptySet())!!) return
        val extra = p.getStringSet(KEY_EXTRA, emptySet())!! + pkg
        p.edit().putStringSet(KEY_EXTRA, extra).apply()
        Log.d(TAG, "learned $pkg")
    }

    /** Installed apps that currently count as banking apps (for the picker). */
    fun installedBankApps(ctx: Context): List<String> =
        AppLock.launchableApps(ctx).map { it.pkg }.filter { isBankApp(ctx, it) }

    /** Saves the picker result: [selected] are the installed apps that should pause the counter. */
    fun setChosen(ctx: Context, selected: Collection<String>) {
        val installed = AppLock.launchableApps(ctx).map { it.pkg }
        val sel = selected.toSet()
        val p = prefs(ctx)
        val oldExtra = p.getStringSet(KEY_EXTRA, emptySet())!!
        val extra = oldExtra.filter { it !in installed } + sel.filter { !isDetected(ctx, it) }
        val excluded = installed.filter { isDetected(ctx, it) && it !in sel }
        p.edit()
            .putStringSet(KEY_EXTRA, extra.toSet())
            .putStringSet(KEY_EXCLUDED, excluded.toSet())
            .apply()
    }

    fun canToggle(ctx: Context) =
        ctx.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    fun hasUsageAccess(ctx: Context): Boolean {
        val ops = ctx.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), ctx.packageName)
        return mode == AppOpsManager.MODE_ALLOWED
    }

    fun isAutoOn(ctx: Context) = prefs(ctx).getBoolean(KEY_AUTO, true)
    fun setAutoOn(ctx: Context, on: Boolean) = prefs(ctx).edit().putBoolean(KEY_AUTO, on).apply()

    fun isPaused() = BankingPauseService.running

    fun status(ctx: Context): Map<String, Any> = mapOf(
        "canToggle" to canToggle(ctx),
        "usageAccess" to hasUsageAccess(ctx),
        "auto" to isAutoOn(ctx),
        "paused" to isPaused(),
    )

    /**
     * Turns the reel counter off while [bankPkg] is open. With WRITE_SECURE_SETTINGS it comes
     * back on by itself; otherwise the service disables itself and a notification offers to
     * turn it back on.
     */
    fun pause(service: ReelCounterService, bankPkg: String?): Boolean {
        if (canToggle(service)) {
            Log.d(TAG, "pause for $bankPkg")
            val i = Intent(service, BankingPauseService::class.java).putExtra("pkg", bankPkg)
            try {
                service.startForegroundService(i)
            } catch (e: Exception) {
                Log.w(TAG, "could not start pause service", e)
            }
            setServiceEnabled(service, false)
        } else {
            Log.d(TAG, "turn off for $bankPkg (no permission to turn back on)")
            postReenableNotification(service, bankPkg)
            service.disableSelf()
        }
        return true
    }

    fun resume(ctx: Context) {
        Log.d(TAG, "resume")
        if (canToggle(ctx)) setServiceEnabled(ctx, true)
        // Not declared in the Play build (src/play/AndroidManifest.xml), where it never runs.
        if (!BuildConfig.PLAY_STORE) ctx.stopService(Intent(ctx, BankingPauseService::class.java))
    }

    /** Called when the service connects: the "turn back on" notification is no longer needed. */
    fun onServiceOn(ctx: Context) {
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .cancel(REENABLE_NOTIFICATION_ID)
    }

    fun createChannel(ctx: Context) {
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
            NotificationChannel(CHANNEL, "Paused for banking", NotificationManager.IMPORTANCE_LOW)
        )
    }

    fun channel() = CHANNEL

    /** Opens this app's accessibility page (or the accessibility list on older phones). */
    fun settingsIntent(ctx: Context): Intent {
        val me = ComponentName(ctx, ReelCounterService::class.java).flattenToString()
        val details = Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS")
            .putExtra(Intent.EXTRA_COMPONENT_NAME, me)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return if (details.resolveActivity(ctx.packageManager) != null) details
        else Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    private fun postReenableNotification(ctx: Context, bankPkg: String?) {
        createChannel(ctx)
        val name = bankPkg?.let { AppLock.appLabel(ctx, it) } ?: "your banking app"
        val open = PendingIntent.getActivity(
            ctx, 1, settingsIntent(ctx), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_pause)
            .setContentTitle("Reel counter is off so $name works")
            .setContentText("When you're done, tap here to turn it back on.")
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        try {
            (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .notify(REENABLE_NOTIFICATION_ID, n)
        } catch (e: SecurityException) {
            Log.w(TAG, "notification permission missing", e)
        }
    }

    private fun setServiceEnabled(ctx: Context, on: Boolean) {
        val cr = ctx.contentResolver
        val me = ComponentName(ctx, ReelCounterService::class.java)
        val others = (Settings.Secure.getString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: "")
            .split(':')
            .filter { it.isNotBlank() && ComponentName.unflattenFromString(it) != me }
        val list = if (on) others + me.flattenToString() else others
        try {
            Settings.Secure.putString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, list.joinToString(":"))
            if (on) Settings.Secure.putString(cr, Settings.Secure.ACCESSIBILITY_ENABLED, "1")
        } catch (e: SecurityException) {
            Log.w(TAG, "WRITE_SECURE_SETTINGS missing", e)
        }
    }

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

/**
 * Runs while the reel counter is paused for banking: shows a "paused" notification with a
 * Resume button and, when usage access is granted, switches the counter back on as soon as
 * an app other than a banking app comes to the front. Without usage access it resumes
 * after [FALLBACK_MS].
 */
class BankingPauseService : Service() {
    companion object {
        @Volatile
        var running = false
            private set

        private const val NOTIFICATION_ID = 4711
        private const val ACTION_RESUME = "resume"
        private const val CHECK_MS = 1500L

        /** With the screen off nobody can switch apps; check rarely to save battery. */
        private const val CHECK_SCREEN_OFF_MS = 15_000L
        private const val FALLBACK_MS = 10 * 60_000L
    }

    private val handler = Handler(Looper.getMainLooper())
    private var startedAt = 0L
    private var lastQuery = 0L
    private var front: String? = null

    private val check = object : Runnable {
        override fun run() {
            val now = System.currentTimeMillis()
            if (BankingMode.hasUsageAccess(this@BankingPauseService)) {
                val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
                val events = usm.queryEvents(lastQuery, now)
                val e = UsageEvents.Event()
                while (events.hasNextEvent()) {
                    events.getNextEvent(e)
                    if (e.eventType == UsageEvents.Event.ACTIVITY_RESUMED) front = e.packageName
                }
                lastQuery = now
                val f = front
                if (f != null && !BankingMode.isBankApp(this@BankingPauseService, f) && f != "com.android.systemui") {
                    BankingMode.resume(this@BankingPauseService)
                    return
                }
            } else if (now - startedAt > FALLBACK_MS) {
                BankingMode.resume(this@BankingPauseService)
                return
            }
            val screenOn = (getSystemService(Context.POWER_SERVICE) as android.os.PowerManager).isInteractive
            handler.postDelayed(this, if (screenOn) CHECK_MS else CHECK_SCREEN_OFF_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_RESUME) {
            BankingMode.resume(this)
            return START_NOT_STICKY
        }
        startInForeground()
        running = true
        startedAt = System.currentTimeMillis()
        lastQuery = startedAt - 2000
        front = intent?.getStringExtra("pkg")
        handler.removeCallbacks(check)
        handler.postDelayed(check, CHECK_MS)
        return START_NOT_STICKY
    }

    private fun startInForeground() {
        BankingMode.createChannel(this)
        val resume = PendingIntent.getService(
            this, 0,
            Intent(this, BankingPauseService::class.java).setAction(ACTION_RESUME),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = Notification.Builder(this, BankingMode.channel())
            .setSmallIcon(android.R.drawable.ic_media_pause)
            .setContentTitle("Reel counter paused")
            .setContentText("So your banking app works. It turns back on when you leave.")
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Resume now", resume).build())
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    override fun onDestroy() {
        running = false
        handler.removeCallbacks(check)
        super.onDestroy()
    }
}
