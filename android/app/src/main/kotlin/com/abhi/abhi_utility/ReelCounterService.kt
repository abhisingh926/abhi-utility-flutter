package com.abhi.abhi_utility

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import android.text.format.DateFormat
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.util.Calendar
import java.util.Date

/**
 * Counts reels / shorts in short-video apps, tracks time spent in them, and shows
 * a small counter on top of the app while it is open.
 *
 * Reel detectors:
 * 1. Scroll events (most apps): a reel feed is a full-screen vertical pager that
 *    shows exactly one item at a time. Each time it settles on a different item,
 *    the user has scrolled to a new reel.
 * 2. YouTube Shorts: YouTube sends no scroll events for Shorts, so while YouTube is
 *    open we read the Shorts progress bar ("7 seconds of 1 minute 1 second") about
 *    once a second. A different length, or a jump back to the start before the end,
 *    means a new Short. A Short looping after it ends is not counted.
 *
 * For other apps only the package name of the app on screen is used (to know when
 * a social app is left). Nothing from the screen is stored except counts and time.
 */
class ReelCounterService : AccessibilityService() {

    companion object {
        private const val TAG = "ReelCounter"
        private const val REPORT_CHANNEL = "reel_report"
        private const val YOUTUBE = "com.google.android.youtube"

        /** Windows that sit on top of an app without leaving it. */
        private val IGNORED_PACKAGES = setOf(
            "com.android.systemui",
            "com.abhi.abhi_utility",
        )

        private const val MIN_HEIGHT_RATIO = 0.7f
        private const val MIN_GAP_MS = 400L
        private const val POLL_SHORTS_MS = 700L
        private const val POLL_IDLE_MS = 2000L

        /** Progress bar missing this long = user left Shorts. */
        private const val SHORTS_GONE_MS = 4000L
        private const val SAVE_TIME_EVERY_MS = 15_000L

        /** How long the counter stays expanded after a new reel. */
        private const val EXPANDED_MS = 3000L

        /** Show the "min left" countdown when this many seconds are left. */
        private const val COUNTDOWN_FROM_S = 120

        /**
         * Apps where the floating ⬇ (download) button appears while a video plays.
         * YouTube is deliberately not included (Google Play policy).
         */
        private val DOWNLOAD_BUBBLE_APPS = setOf(
            // Browsers
            "com.android.chrome", "com.chrome.beta", "com.sec.android.app.sbrowser", "org.mozilla.firefox",
            "com.microsoft.emmx", "com.opera.browser", "com.opera.mini.native", "com.brave.browser",
            "com.duckduckgo.mobile.android", "com.kiwibrowser.browser", "com.vivaldi.browser",
            // Social / video apps
            "com.instagram.android", "com.instagram.barcelona", "com.facebook.katana", "com.facebook.lite",
            "com.snapchat.android", "com.twitter.android", "com.reddit.frontpage", "com.pinterest",
            "com.linkedin.android", "org.telegram.messenger", "com.tumblr", "com.vimeo.android.videoapp",
            "com.dailymotion.dailymotion", "in.mohalla.video", "in.mohalla.sharechat",
            "com.eterno.shortvideos", "com.zhiliaoapp.musically", "com.ss.android.ugc.trill",
            // WhatsApp: the ⬇ button opens the Status Saver (statuses have no link).
            "com.whatsapp", "com.whatsapp.w4b",
        )

        private val WHATSAPP_APPS = setOf("com.whatsapp", "com.whatsapp.w4b")

        /** Keep the ⬇ button a moment after playback stops (no flicker between videos). */
        private const val BUBBLE_HIDE_DELAY_MS = 2500L
    }

    // Download bubble.
    private var anyForegroundPkg: String? = null
    private var mediaPlaying = false
    private var bubbleView: TextView? = null
    private var audioManager: AudioManager? = null

    private val audioCallback = object : AudioManager.AudioPlaybackCallback() {
        override fun onPlaybackConfigChanged(configs: MutableList<AudioPlaybackConfiguration>) {
            mediaPlaying = isMediaPlaying(configs)
            updateBubble()
            // The locked app started playing again behind the lock screen: stop it again.
            if (mediaPlaying && blockedPkg != null) silenceMedia()
        }
    }

    // ---- Stopping sound/video behind the lock screen ---------------------------------

    /** Audio focus held while an app is locked, so its video pauses and stays paused. */
    private val lockFocusRequest by lazy {
        AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build()
            )
            .setWillPauseWhenDucked(true)
            // The locked app took focus back to play: ask again next time.
            .setOnAudioFocusChangeListener { change ->
                if (change != AudioManager.AUDIOFOCUS_GAIN) holdingFocus = false
            }
            .build()
    }
    private var holdingFocus = false
    private var mutedByLock = false

    /** If the app ignores audio focus and the pause key, mute media until it is unlocked. */
    private val muteIfStillPlaying = Runnable {
        val am = audioManager ?: return@Runnable
        if (blockedPkg == null || mutedByLock) return@Runnable
        if (!isMediaPlaying(am.activePlaybackConfigurations)) return@Runnable
        try {
            am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)
            mutedByLock = true
            Log.d(TAG, "media muted while locked")
        } catch (e: Exception) {
            Log.w(TAG, "Could not mute media", e)
        }
    }

    /** Pauses the video/sound of the locked app (it keeps running under the lock screen). */
    private fun silenceMedia() {
        val am = audioManager ?: return
        // 1. Take audio focus: Instagram, YouTube & co. pause when they lose it.
        if (!holdingFocus) {
            holdingFocus = am.requestAudioFocus(lockFocusRequest) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
        // 2. Press "pause" for the app's media session (headphone-button pause).
        try {
            am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PAUSE))
            am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MEDIA_PAUSE))
        } catch (e: Exception) {
            Log.w(TAG, "Could not send pause", e)
        }
        // 3. Last resort: mute if it still plays shortly after.
        handler.removeCallbacks(muteIfStillPlaying)
        handler.postDelayed(muteIfStillPlaying, 800)
    }

    /** Gives sound back once the app is unlocked or left. */
    private fun restoreMedia() {
        handler.removeCallbacks(muteIfStillPlaying)
        val am = audioManager ?: return
        if (mutedByLock) {
            try {
                am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
            } catch (e: Exception) {
                Log.w(TAG, "Could not unmute media", e)
            }
            mutedByLock = false
        }
        if (holdingFocus) {
            am.abandonAudioFocusRequest(lockFocusRequest)
            holdingFocus = false
        }
    }

    private fun isMediaPlaying(configs: List<AudioPlaybackConfiguration>) = configs.any {
        val usage = it.audioAttributes.usage
        usage == AudioAttributes.USAGE_MEDIA || usage == AudioAttributes.USAGE_GAME ||
            usage == AudioAttributes.USAGE_UNKNOWN
    }

    private val hideBubbleTask = Runnable { if (!shouldShowBubble()) hideBubble() }

    private val handler = Handler(Looper.getMainLooper())

    // Detector 1 state.
    private val lastIndex = HashMap<String, Int>()
    private val lastCountTime = HashMap<String, Long>()

    // Detector 2 state (seconds).
    private var polling = false
    private var ytPos = -1
    private var ytDur = -1
    private var ytMissingSince = 0L

    // Foreground app + time tracking.
    private var fgPkg: String? = null
    private var fgSince = 0L       // elapsedRealtime from which time is not yet saved
    private var lastSave = 0L

    // Overlay.
    private var windowManager: WindowManager? = null
    private var overlay: TextView? = null
    private var expandedUntil = 0L

    // App lock.
    private var lockRules: Map<String, AppLock.Rule> = emptyMap()
    private var blockView: View? = null
    private var blockedPkg: String? = null
    private var countdownView: TextView? = null
    private var pinView: View? = null

    /** Apps whose time is tracked: reel apps plus apps with a lock rule. */
    private fun isTracked(pkg: String) = pkg in ReelApps.NAMES || pkg in lockRules

    private val pollTask = object : Runnable {
        override fun run() {
            val delay = pollYouTube()
            if (delay == null) {
                polling = false
                resetYouTube()
            } else {
                handler.postDelayed(this, delay)
            }
        }
    }

    /** Every second while a tracked app is open: check locks, refresh the counter, save time. */
    private val tickTask = object : Runnable {
        override fun run() {
            if (fgPkg == null) return
            if (SystemClock.elapsedRealtime() - lastSave >= SAVE_TIME_EVERY_MS) saveTime()
            checkLock()
            updateOverlay()
            handler.postDelayed(this, 1000)
        }
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    setForeground(null)
                    anyForegroundPkg = null
                    updateBubble()
                }
                Intent.ACTION_USER_PRESENT, Intent.ACTION_SCREEN_ON ->
                    setForeground(rootInActiveWindow?.packageName?.toString())
            }
        }
    }

    override fun onServiceConnected() {
        Log.d(TAG, "service connected")
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(screenReceiver, filter, RECEIVER_NOT_EXPORTED)
        else registerReceiver(screenReceiver, filter)
        // A social app may already be open (e.g. right after the app was updated).
        setForeground(rootInActiveWindow?.packageName?.toString())

        // Know when any app plays a video (for the ⬇ download button).
        audioManager = (getSystemService(Context.AUDIO_SERVICE) as AudioManager).also {
            it.registerAudioPlaybackCallback(audioCallback, handler)
            mediaPlaying = isMediaPlaying(it.activePlaybackConfigurations)
        }
        anyForegroundPkg = rootInActiveWindow?.packageName?.toString()
        updateBubble()
    }

    // ---- Download bubble ------------------------------------------------------------

    private fun shouldShowBubble(): Boolean =
        // WhatsApp: always while it's open — photo statuses make no sound, so
        // "media playing" would never show the button there.
        (mediaPlaying || anyForegroundPkg in WHATSAPP_APPS) &&
            anyForegroundPkg in DOWNLOAD_BUBBLE_APPS &&
            blockedPkg == null && pinView == null &&
            Downloads.bubbleEnabled(this)

    private fun updateBubble() {
        if (shouldShowBubble()) {
            handler.removeCallbacks(hideBubbleTask)
            showBubble()
        } else if (bubbleView != null) {
            handler.removeCallbacks(hideBubbleTask)
            // Leaving the app: hide now. Video paused/switching: wait a little.
            if (anyForegroundPkg !in DOWNLOAD_BUBBLE_APPS) hideBubble()
            else handler.postDelayed(hideBubbleTask, BUBBLE_HIDE_DELAY_MS)
        }
    }

    private fun showBubble() {
        if (bubbleView != null) return
        val wm = windowManager ?: return
        val view = TextView(this).apply {
            text = "⬇"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.argb(215, 20, 20, 40))
                setStroke(dp(2f), Color.rgb(0, 200, 120))
            }
            contentDescription = "Download this video with Abhi Utility"
            setOnClickListener {
                // WhatsApp -> Status Saver; elsewhere the Downloader reads the copied link.
                val target = if (anyForegroundPkg in WHATSAPP_APPS) "status" else "downloader"
                startActivity(
                    Intent(this@ReelCounterService, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        .putExtra(MainActivity.EXTRA_OPEN, target)
                )
            }
        }
        val size = dp(42f)
        val params = WindowManager.LayoutParams(
            size, size,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            x = dp(10f)
            y = statusBarHeight() + dp(40f) // just below the reel counter
        }
        try {
            wm.addView(view, params)
            bubbleView = view
        } catch (e: Exception) {
            Log.w(TAG, "Could not show download button", e)
        }
    }

    private fun hideBubble() {
        bubbleView?.let {
            try {
                windowManager?.removeView(it)
            } catch (_: Exception) {
            }
        }
        bubbleView = null
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        val pkg = event.packageName?.toString() ?: return

        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            // Which app is really in front (a keyboard or dialog event shouldn't count).
            val active = rootInActiveWindow?.packageName?.toString() ?: pkg
            if (active !in IGNORED_PACKAGES) setForeground(active)
            // Includes this app itself, so the ⬇ button hides when Abhi Utility opens.
            if (active != "com.android.systemui") {
                anyForegroundPkg = active
                updateBubble()
            }
            if (pkg in ReelApps.NAMES) lastIndex.keys.removeAll { it.startsWith("$pkg|") }
        }

        if (!isTracked(pkg)) return
        // Missed the screen change (e.g. service restarted while the app was open).
        if (fgPkg != pkg && rootInActiveWindow?.packageName?.toString() == pkg) setForeground(pkg)
        if (pkg in ReelApps.NAMES && event.eventType == AccessibilityEvent.TYPE_VIEW_SCROLLED) {
            onScroll(pkg, event)
        }
    }

    // ---- Foreground app, time and overlay -------------------------------------------

    private fun setForeground(pkg: String?) {
        lockRules = AppLock.rules(this) // the user may have changed them in the app
        val next = pkg?.takeIf { isTracked(it) }
        if (next == fgPkg) return
        saveTime()
        fgPkg = next
        handler.removeCallbacks(tickTask)
        hideBlockScreen()
        hideCountdown()
        hidePinPad()
        if (next == null) {
            hideOverlay()
            return
        }
        fgSince = SystemClock.elapsedRealtime()
        lastSave = fgSince
        if (next == YOUTUBE && !polling) {
            polling = true
            handler.post(pollTask)
        }
        if (next in ReelApps.NAMES) showOverlay() else hideOverlay()
        checkLock()
        handler.post(tickTask)
    }

    /** Saves the time spent in the current app since the last save. */
    private fun saveTime() {
        val pkg = fgPkg ?: return
        val now = SystemClock.elapsedRealtime()
        val secs = ((now - fgSince) / 1000).toInt()
        if (secs > 0) {
            // Time behind the lock screen isn't real use.
            if (blockedPkg != pkg) ReelStats.addSeconds(this, pkg, secs)
            fgSince += secs * 1000L
        }
        lastSave = now
    }

    private fun unsavedSeconds() = ((SystemClock.elapsedRealtime() - fgSince) / 1000).toInt()

    // ---- App lock -------------------------------------------------------------------

    /** Locks the open app if its rule says so; warns 1 minute before. */
    private fun checkLock() {
        val pkg = fgPkg ?: return
        val rule = lockRules[pkg]
        if (rule == null) {
            hideBlockScreen()
            hideCountdown()
            return
        }
        val unsaved = if (blockedPkg == pkg) 0 else unsavedSeconds()
        val status = AppLock.status(this, pkg, rule, unsaved)
        if (status.locked) {
            hideCountdown()
            // While the password pad is open, wait: the parent may be adding time.
            if (blockedPkg != pkg && pinView == null) {
                saveTime() // count the time up to the lock
                showBlockScreen(pkg, rule, status)
            }
            return
        }
        hideBlockScreen()
        if (status.remainingSeconds <= COUNTDOWN_FROM_S) showCountdown(pkg, status.remainingSeconds)
        else hideCountdown()
    }

    // ---- Countdown pill ("2 min left" … "Locking in 3") -----------------------------

    private fun showCountdown(pkg: String, remaining: Int) {
        val wm = windowManager ?: return
        val view = countdownView ?: TextView(this).apply {
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setPadding(dp(16f), dp(8f), dp(16f), dp(8f))
            // Tap: parent enters the password to give more time.
            setOnClickListener { fgPkg?.let { showPinPad(it, fromLockScreen = false) } }
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                y = statusBarHeight() + dp(48f)
            }
            try {
                wm.addView(this, params)
            } catch (e: Exception) {
                Log.w(TAG, "Could not show countdown", e)
                return
            }
            countdownView = this
        }
        val finalSeconds = remaining <= 10
        view.text = when {
            finalSeconds -> "🔒 Locking in $remaining\nTap to add time"
            remaining <= 60 -> "⏳ 1 min left · tap to add time"
            else -> "⏳ ${(remaining + 59) / 60} min left · tap to add time"
        }
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, if (finalSeconds) 20f else 13f)
        view.background = GradientDrawable().apply {
            cornerRadius = dp(22f).toFloat()
            setColor(if (finalSeconds) Color.argb(235, 210, 30, 50) else Color.argb(220, 20, 20, 40))
            setStroke(dp(1f), Color.argb(160, 255, 170, 0))
        }
    }

    private fun hideCountdown() {
        countdownView?.let {
            try {
                windowManager?.removeView(it)
            } catch (_: Exception) {
            }
        }
        countdownView = null
    }

    private fun statusBarHeight(): Int {
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else dp(28f)
    }

    // ---- Password pad + extra time ----------------------------------------------------

    /** Full-screen number pad; after the right password, choose how much time to add. */
    private fun showPinPad(pkg: String, fromLockScreen: Boolean) {
        hidePinPad()
        val wm = windowManager ?: return
        val rule = lockRules[pkg] ?: return
        val name = AppLock.appLabel(this, pkg)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(32f), dp(32f), dp(32f), dp(32f))
            setBackgroundColor(Color.rgb(12, 14, 40))
        }
        fun title(text: String, sizeSp: Float, alpha: Int = 255) = TextView(this).apply {
            this.text = text
            setTextColor(Color.argb(alpha, 255, 255, 255))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
            gravity = Gravity.CENTER
        }
        fun pillButton(text: String, filled: Boolean, onClick: () -> Unit) = Button(this).apply {
            this.text = text
            isAllCaps = false
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTextColor(if (filled) Color.BLACK else Color.WHITE)
            background = GradientDrawable().apply {
                cornerRadius = dp(24f).toFloat()
                if (filled) setColor(Color.rgb(0, 210, 255))
                else { setColor(Color.TRANSPARENT); setStroke(dp(1f), Color.argb(120, 255, 255, 255)) }
            }
            setOnClickListener { onClick() }
        }

        if (!AppLock.hasPin(this)) {
            root.addView(title("No password set", 22f))
            root.addView(title("\nSet a password in Abhi Utility → App Lock to give extra time.\n", 15f, 200))
            root.addView(pillButton("OK", true) { hidePinPad() })
        } else {
            var entered = ""
            val dots = title("", 30f)
            val error = title("", 14f).apply { setTextColor(Color.rgb(255, 110, 110)) }
            fun render() { dots.text = if (entered.isEmpty()) "– – – –" else "● ".repeat(entered.length).trim() }
            render()

            root.addView(title("🔑 Enter password", 22f))
            root.addView(title("to give $name more time", 15f, 200))
            root.addView(dots, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(20f) })
            root.addView(error, LinearLayout.LayoutParams(-2, -2).apply { bottomMargin = dp(12f) })

            fun onOk() {
                if (AppLock.checkPin(this, entered)) {
                    showTimeOptions(root, pkg, rule, name, ::title, ::pillButton)
                } else {
                    entered = ""
                    error.text = "Wrong password"
                    render()
                }
            }

            val keys = listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "OK")
            val grid = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
            keys.chunked(3).forEach { rowKeys ->
                val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
                rowKeys.forEach { k ->
                    row.addView(Button(this).apply {
                        text = k
                        setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
                        setTextColor(if (k == "OK") Color.BLACK else Color.WHITE)
                        background = GradientDrawable().apply {
                            shape = GradientDrawable.OVAL
                            setColor(if (k == "OK") Color.rgb(0, 210, 255) else Color.argb(40, 255, 255, 255))
                        }
                        setOnClickListener {
                            error.text = ""
                            when (k) {
                                "⌫" -> entered = entered.dropLast(1)
                                "OK" -> { onOk(); return@setOnClickListener }
                                else -> if (entered.length < 6) entered += k
                            }
                            render()
                        }
                    }, LinearLayout.LayoutParams(dp(72f), dp(72f)).apply { setMargins(dp(10f), dp(8f), dp(10f), dp(8f)) })
                }
                grid.addView(row)
            }
            root.addView(grid)
            root.addView(pillButton("Cancel", false) { hidePinPad() },
                LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(20f) })
        }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.OPAQUE
        )
        try {
            wm.addView(root, params)
            pinView = root
            hideCountdown()
        } catch (e: Exception) {
            Log.w(TAG, "Could not show password pad", e)
        }
    }

    private fun showTimeOptions(
        root: LinearLayout,
        pkg: String,
        rule: AppLock.Rule,
        name: String,
        title: (String, Float, Int) -> TextView,
        pillButton: (String, Boolean, () -> Unit) -> Button,
    ) {
        root.removeAllViews()
        root.addView(title("✅ Password correct", 22f, 255))
        root.addView(title("How much more time for $name?", 16f, 200),
            LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(8f); bottomMargin = dp(24f) })
        listOf(5, 10, 15, 30, 60).forEach { min ->
            root.addView(pillButton(if (min == 60) "+1 hour" else "+$min min", true) {
                AppLock.addBonus(this, pkg, rule, min * 60)
                Log.d(TAG, "added $min min for $pkg")
                hidePinPad()
                checkLock() // unlocks right away
            }, LinearLayout.LayoutParams(dp(220f), -2).apply { setMargins(0, dp(6f), 0, dp(6f)) })
        }
        root.addView(pillButton("Cancel", false) { hidePinPad() },
            LinearLayout.LayoutParams(dp(220f), -2).apply { topMargin = dp(18f) })
    }

    private fun hidePinPad() {
        pinView?.let {
            try {
                windowManager?.removeView(it)
            } catch (_: Exception) {
            }
        }
        pinView = null
    }

    private fun showBlockScreen(pkg: String, rule: AppLock.Rule, status: AppLock.Status) {
        hideBlockScreen()
        val wm = windowManager ?: return
        val name = AppLock.appLabel(this, pkg)
        val until = status.unlockAt?.let {
            DateFormat.getTimeFormat(this).format(Date(it))
        }
        val message = when (rule.mode) {
            "daily" -> "You've used your ${rule.minutes} min for today.\nUnlocks tomorrow at $until."
            "hourly" -> "You've used your ${rule.minutes} min for this hour.\nUnlocks at $until."
            else -> "This app is locked.\nYou can change this in Abhi Utility → App Lock."
        }

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(32f), dp(32f), dp(32f), dp(32f))
            setBackgroundColor(Color.rgb(12, 14, 40))

            try {
                addView(ImageView(context).apply {
                    setImageDrawable(packageManager.getApplicationIcon(pkg))
                }, LinearLayout.LayoutParams(dp(72f), dp(72f)).apply { bottomMargin = dp(20f) })
            } catch (_: Exception) {
            }
            addView(TextView(context).apply {
                text = "🔒 $name is locked"
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
                typeface = Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER
            })
            addView(TextView(context).apply {
                text = message
                setTextColor(Color.argb(200, 255, 255, 255))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                gravity = Gravity.CENTER
                setLineSpacing(0f, 1.3f)
            }, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(12f); bottomMargin = dp(32f) })
            addView(Button(context).apply {
                text = "Close app"
                isAllCaps = false
                setTextColor(Color.BLACK)
                background = GradientDrawable().apply {
                    cornerRadius = dp(24f).toFloat()
                    setColor(Color.rgb(0, 210, 255))
                }
                setPadding(dp(32f), dp(12f), dp(32f), dp(12f))
                setOnClickListener { performGlobalAction(GLOBAL_ACTION_HOME) }
            }, LinearLayout.LayoutParams(dp(240f), -2))
            addView(Button(context).apply {
                text = "🔑 Unlock with password"
                isAllCaps = false
                setTextColor(Color.WHITE)
                background = GradientDrawable().apply {
                    cornerRadius = dp(24f).toFloat()
                    setColor(Color.TRANSPARENT)
                    setStroke(dp(1f), Color.argb(140, 255, 255, 255))
                }
                setPadding(dp(32f), dp(12f), dp(32f), dp(12f))
                setOnClickListener { showPinPad(pkg, fromLockScreen = true) }
            }, LinearLayout.LayoutParams(dp(240f), -2).apply { topMargin = dp(12f) })
        }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.OPAQUE
        )
        try {
            wm.addView(column, params)
            blockView = column
            blockedPkg = pkg
            hideOverlay()
            silenceMedia()
            Log.d(TAG, "locked $pkg (${rule.mode} ${rule.minutes} min)")
        } catch (e: Exception) {
            Log.w(TAG, "Could not show lock screen", e)
            performGlobalAction(GLOBAL_ACTION_HOME)
        }
    }

    private fun hideBlockScreen() {
        val view = blockView ?: return
        try {
            windowManager?.removeView(view)
        } catch (_: Exception) {
        }
        blockView = null
        val pkg = blockedPkg
        blockedPkg = null
        restoreMedia()
        // Back to normal use (e.g. the hour rolled over): restart the clock and the counter.
        if (pkg != null && pkg == fgPkg) {
            fgSince = SystemClock.elapsedRealtime()
            if (pkg in ReelApps.NAMES) showOverlay()
        }
    }

    private fun dp(v: Float) =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics).toInt()

    private fun showOverlay() {
        if (!ReelStats.isOverlayEnabled(this)) {
            hideOverlay()
            return
        }
        val wm = windowManager ?: return
        if (overlay == null) {
            val view = TextView(this).apply {
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                typeface = Typeface.DEFAULT_BOLD
                gravity = Gravity.END
                setPadding(dp(10f), dp(4f), dp(10f), dp(4f))
                background = GradientDrawable().apply {
                    cornerRadius = dp(18f).toFloat()
                    setColor(Color.argb(190, 20, 20, 40))
                    setStroke(dp(1f), Color.argb(120, 0, 200, 255))
                }
            }
            val statusBarId = resources.getIdentifier("status_bar_height", "dimen", "android")
            val statusBar = if (statusBarId > 0) resources.getDimensionPixelSize(statusBarId) else dp(28f)
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.TOP or Gravity.END
                x = dp(8f)
                y = statusBar + dp(4f)
            }
            try {
                wm.addView(view, params)
                overlay = view
            } catch (e: Exception) {
                Log.w(TAG, "Could not show overlay", e)
                return
            }
        }
        updateOverlay()
    }

    private fun updateOverlay() {
        val view = overlay ?: return
        val pkg = fgPkg ?: return
        if (pkg !in ReelApps.NAMES || blockedPkg != null) return
        if (!ReelStats.isOverlayEnabled(this)) {
            hideOverlay()
            return
        }
        val counts = ReelStats.todayCounts(this)
        val secs = (ReelStats.todaySeconds(this)[pkg] ?: 0) +
            ((SystemClock.elapsedRealtime() - fgSince) / 1000).toInt()
        val appReels = counts[pkg] ?: 0
        val allReels = counts.values.sum()
        val name = ReelApps.NAMES[pkg] ?: ""
        val minutes = secs / 60
        val time = if (minutes >= 60) "${minutes / 60}h ${minutes % 60}m" else "$minutes min"

        // Small by default; expanded for a few seconds after each new reel.
        view.text = if (SystemClock.elapsedRealtime() < expandedUntil) {
            "🎬 $appReels reels  ·  ⏱ $time\n$name today · all apps: $allReels"
        } else {
            "🎬 $appReels"
        }
    }

    private fun hideOverlay() {
        overlay?.let {
            try {
                windowManager?.removeView(it)
            } catch (_: Exception) {
            }
        }
        overlay = null
    }

    // ---- Detector 1: scroll events -------------------------------------------------

    private fun onScroll(pkg: String, event: AccessibilityEvent) {
        if (pkg == YOUTUBE) return // handled by the Shorts progress detector
        val source = event.source ?: return
        val bounds = Rect().also { source.getBoundsInScreen(it) }
        val viewId = source.viewIdResourceName ?: event.className?.toString() ?: "?"
        val screenH = resources.displayMetrics.heightPixels
        val from = event.fromIndex
        val to = event.toIndex

        Log.d(TAG, "scroll pkg=$pkg id=$viewId h=${bounds.height()}/$screenH from=$from to=$to")

        if (bounds.height() < screenH * MIN_HEIGHT_RATIO) return
        if (from < 0 || from != to) return // several items visible: a normal feed, or mid-swipe

        val key = "$pkg|$viewId"
        val prev = lastIndex.put(key, from)
        if (prev == null || prev == from) return
        count(pkg, "item $prev -> $from")
    }

    // ---- Detector 2: YouTube Shorts progress bar ------------------------------------

    /** Returns the delay until the next check, or null to stop (YouTube left / screen off). */
    private fun pollYouTube(): Long? {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (!pm.isInteractive) return null
        val root = rootInActiveWindow ?: return null
        if (root.packageName?.toString() != YOUTUBE) return null
        root.refresh() // the node cache goes stale: we don't subscribe to content-change events

        val label = findShortsProgress(root)
        val now = SystemClock.elapsedRealtime()
        if (label == null) {
            // The progress bar briefly disappears during every swipe, so only forget
            // the last Short once it has been gone for a while (user left Shorts).
            if (ytMissingSince == 0L) ytMissingSince = now
            if (now - ytMissingSince > SHORTS_GONE_MS) resetYouTube()
            return if (ytDur > 0) POLL_SHORTS_MS else POLL_IDLE_MS
        }
        ytMissingSince = 0L
        val parts = label.split(" of ")
        if (parts.size != 2) return POLL_SHORTS_MS
        val pos = parseSeconds(parts[0])
        val dur = parseSeconds(parts[1])
        if (pos < 0 || dur <= 0) return POLL_SHORTS_MS

        if (ytDur > 0) {
            val otherLength = dur != ytDur
            // Jumped back to the start while the previous Short wasn't near its end.
            val restartedMidway = pos + 1 < ytPos && ytPos < ytDur - 2
            if (otherLength || restartedMidway) {
                count(YOUTUBE, "short ${ytPos}s/${ytDur}s -> ${pos}s/${dur}s")
            }
        }
        ytPos = pos
        ytDur = dur
        return POLL_SHORTS_MS
    }

    private fun resetYouTube() {
        ytPos = -1
        ytDur = -1
        ytMissingSince = 0L
    }

    /** Finds the Shorts SeekBar label, e.g. "0 minutes 7 seconds of 1 minute 1 second". */
    private fun findShortsProgress(root: AccessibilityNodeInfo): String? {
        val bars = root.findAccessibilityNodeInfosByViewId("$YOUTUBE:id/reel_time_bar")
        for (bar in bars) findSeekBarLabel(bar, 0)?.let { return it }
        return null
    }

    private fun findSeekBarLabel(node: AccessibilityNodeInfo, depth: Int): String? {
        node.refresh() // read the live label, not a cached copy
        if (node.className?.toString()?.endsWith("SeekBar") == true) {
            node.contentDescription?.toString()?.let { return it }
        }
        if (depth > 4) return null
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            findSeekBarLabel(child, depth + 1)?.let { return it }
        }
        return null
    }

    /** "1 minute 1 second" -> 61. Returns -1 if nothing could be read. */
    private fun parseSeconds(text: String): Int {
        var total = 0
        var found = false
        Regex("""(\d+)\s*(hour|minute|second)""").findAll(text).forEach {
            val n = it.groupValues[1].toInt()
            total += when (it.groupValues[2]) {
                "hour" -> n * 3600
                "minute" -> n * 60
                else -> n
            }
            found = true
        }
        return if (found) total else -1
    }

    // ---- Counting and daily report --------------------------------------------------

    private fun count(pkg: String, why: String) {
        val now = SystemClock.elapsedRealtime()
        if (now - (lastCountTime[pkg] ?: 0L) < MIN_GAP_MS) return
        lastCountTime[pkg] = now
        Log.d(TAG, "REEL counted for $pkg ($why)")
        ReelStats.increment(this, pkg)?.let { (day, counts) -> postDailyReport(day, counts) }
        expandedUntil = now + EXPANDED_MS
        updateOverlay() // the 1-second tick shrinks it back afterwards
    }

    /** Shows yesterday's totals once, on the first reel of a new day. */
    private fun postDailyReport(day: String, counts: Map<String, Int>) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(REPORT_CHANNEL, "Daily reel report", NotificationManager.IMPORTANCE_DEFAULT)
            )
        }
        val total = counts.values.sum()
        val detail = counts.entries.sortedByDescending { it.value }
            .joinToString(" · ") { "${ReelApps.NAMES[it.key] ?: it.key} ${it.value}" }

        val open = PendingIntent.getActivity(
            this, 2, Intent(this, MainActivity::class.java).putExtra("tab", "reels"),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, REPORT_CHANNEL) else Notification.Builder(this)
        val n = builder
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("Yesterday you scrolled $total reels")
            .setContentText(detail)
            .setStyle(Notification.BigTextStyle().bigText("$day\n$detail"))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        try {
            nm.notify(2, n)
        } catch (e: SecurityException) {
            Log.w(TAG, "Notification permission missing", e)
        }
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        saveTime()
        hideOverlay()
        hideBlockScreen()
        hideCountdown()
        hidePinPad()
        hideBubble()
        handler.removeCallbacks(hideBubbleTask)
        audioManager?.unregisterAudioPlaybackCallback(audioCallback)
        handler.removeCallbacks(pollTask)
        handler.removeCallbacks(tickTask)
        try {
            unregisterReceiver(screenReceiver)
        } catch (_: Exception) {
        }
        super.onDestroy()
    }
}
