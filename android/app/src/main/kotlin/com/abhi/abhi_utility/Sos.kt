package com.abhi.abhi_utility

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.PointF
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.CallLog
import android.telephony.SmsManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import org.json.JSONArray
import org.json.JSONObject

/**
 * SOS: draw an "S" on the lock screen and the SOS contacts are called one after
 * another until someone answers.
 *
 * Settings live here; [SosController] (owned by [ReelCounterService]) shows the
 * invisible drawing strip over the lock screen and places the calls.
 */
object Sos {
    private const val PREFS = "sos"
    private const val KEY_ON = "on"
    private const val KEY_CONTACTS = "contacts"

    /** Broadcast of the notification's "Stop SOS" button. */
    const val ACTION_STOP = "com.abhi.abhi_utility.SOS_STOP"

    /** Signature permission (AndroidManifest.xml) guarding [ACTION_STOP] before Android 13. */
    const val STOP_PERMISSION = "com.abhi.abhi_utility.permission.SOS_CONTROL"

    /** Call, see when a call ends, and read the call log to know if it was answered. */
    val PERMISSIONS = arrayOf(
        Manifest.permission.CALL_PHONE,
        Manifest.permission.READ_PHONE_STATE,
        Manifest.permission.READ_CALL_LOG,
    )

    data class Contact(val name: String, val number: String) {
        val label get() = name.ifBlank { number }
    }

    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isOn(c: Context) = prefs(c).getBoolean(KEY_ON, false)

    fun setOn(c: Context, on: Boolean) = prefs(c).edit().putBoolean(KEY_ON, on).apply()

    /** In calling order. */
    fun contacts(c: Context): List<Contact> = try {
        val a = JSONArray(prefs(c).getString(KEY_CONTACTS, "[]"))
        (0 until a.length()).map {
            val o = a.getJSONObject(it)
            Contact(o.optString("name"), o.optString("number"))
        }.filter { it.number.isNotBlank() }
    } catch (_: Exception) {
        emptyList()
    }

    fun setContacts(c: Context, list: List<Map<String, String>>) {
        val a = JSONArray()
        list.forEach { a.put(JSONObject().put("name", it["name"] ?: "").put("number", it["number"] ?: "")) }
        prefs(c).edit().putString(KEY_CONTACTS, a.toString()).apply()
    }

    fun contactMaps(c: Context) = contacts(c).map { mapOf("name" to it.name, "number" to it.number) }

    // ---- When no one answers ------------------------------------------------------------

    private const val KEY_SMS_LOCATION = "smsLocation"
    private const val KEY_RECORD = "record"
    private const val KEY_UPLOAD_KEY = "uploadKey"
    private const val KEY_UPLOAD_URL = "uploadBaseUrl"
    private const val KEY_UPLOAD_USER = "uploadUserId"
    private const val KEY_SENDER_NAME = "senderName"

    /** How long the video (with sound) is recorded. */
    const val RECORD_SECONDS = 30

    /** Text the current location to every SOS contact. */
    val LOCATION_SMS_PERMISSIONS = arrayOf(
        Manifest.permission.SEND_SMS,
        Manifest.permission.ACCESS_FINE_LOCATION,
        Manifest.permission.ACCESS_COARSE_LOCATION,
    )

    /** Record video + sound (the link is texted, so SMS too). */
    val RECORD_PERMISSIONS = arrayOf(
        Manifest.permission.CAMERA,
        Manifest.permission.RECORD_AUDIO,
        Manifest.permission.SEND_SMS,
    )

    fun smsLocation(c: Context) = prefs(c).getBoolean(KEY_SMS_LOCATION, false)
    fun record(c: Context) = prefs(c).getBoolean(KEY_RECORD, false)

    fun setNoAnswer(c: Context, smsLocation: Boolean, record: Boolean) =
        prefs(c).edit().putBoolean(KEY_SMS_LOCATION, smsLocation).putBoolean(KEY_RECORD, record).apply()

    fun missing(c: Context, perms: Array<String>) =
        perms.filter { c.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }

    fun has(c: Context, perm: String) = c.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED

    /** Server upload of the recording (SOS key from the logged-in account). */
    data class Upload(val key: String, val baseUrl: String, val userId: Int)

    fun upload(c: Context): Upload? {
        val p = prefs(c)
        val key = p.getString(KEY_UPLOAD_KEY, null) ?: return null
        val url = p.getString(KEY_UPLOAD_URL, null) ?: return null
        return Upload(key, url, p.getInt(KEY_UPLOAD_USER, 0))
    }

    fun setUpload(c: Context, upload: Upload?, senderName: String?) {
        val e = prefs(c).edit()
        if (upload == null) {
            e.remove(KEY_UPLOAD_KEY).remove(KEY_UPLOAD_URL).remove(KEY_UPLOAD_USER).remove(KEY_SENDER_NAME)
        } else {
            e.putString(KEY_UPLOAD_KEY, upload.key).putString(KEY_UPLOAD_URL, upload.baseUrl.trimEnd('/'))
                .putInt(KEY_UPLOAD_USER, upload.userId).putString(KEY_SENDER_NAME, senderName ?: "")
        }
        e.apply()
    }

    fun senderName(c: Context) = prefs(c).getString(KEY_SENDER_NAME, "")?.trim().orEmpty()

    /** Something to do after no one answered (and the permissions for it). */
    fun wantsNoAnswerHelp(c: Context) =
        (smsLocation(c) && has(c, Manifest.permission.SEND_SMS)) ||
            (record(c) && has(c, Manifest.permission.CAMERA) && upload(c) != null)

    /** Texts [text] to every SOS contact. Returns how many messages were handed to the phone. */
    fun smsAll(c: Context, text: String): Int {
        if (!has(c, Manifest.permission.SEND_SMS)) return 0
        val sms = if (Build.VERSION.SDK_INT >= 31) {
            c.getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        } ?: return 0
        var sent = 0
        for (contact in contacts(c)) {
            try {
                val parts = sms.divideMessage(text)
                if (parts.size > 1) sms.sendMultipartTextMessage(contact.number, null, parts, null, null)
                else sms.sendTextMessage(contact.number, null, text, null, null)
                sent++
            } catch (e: Exception) {
                Log.w("Sos", "Could not text ${contact.number}", e)
            }
        }
        return sent
    }

    /** "SOS! Asha needs help." / "SOS! I need help." */
    fun smsOpening(c: Context): String {
        val name = senderName(c)
        return if (name.isEmpty()) "SOS! I need help." else "SOS! $name needs help."
    }

    fun missingPermissions(c: Context) =
        PERMISSIONS.filter { c.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }

    /** On, has contacts and may call. */
    fun ready(c: Context) = isOn(c) && contacts(c).isNotEmpty() && missingPermissions(c).isEmpty()

    /**
     * True if [pts] (one finger stroke, screen coordinates) look like an "S":
     * starts top-right, sweeps left, right, left while going down, ends bottom-left.
     */
    fun isS(pts: List<PointF>, minSizePx: Float): Boolean = whyNotS(pts, minSizePx) == null

    /** Null when [pts] is an "S", else the reason it isn't (logged to tune the check). */
    fun whyNotS(pts: List<PointF>, minSizePx: Float): String? {
        if (pts.size < 8) return "too few points (${pts.size})"
        val minX = pts.minOf { it.x }
        val maxX = pts.maxOf { it.x }
        val minY = pts.minOf { it.y }
        val maxY = pts.maxOf { it.y }
        val w = maxX - minX
        val h = maxY - minY
        if (h < minSizePx || w < minSizePx * 0.35f) return "too small h=${h.toInt()} w=${w.toInt()} min=${minSizePx.toInt()}"
        if (h < w * 0.6f) return "too flat h=${h.toInt()} w=${w.toInt()}" // too flat for an S

        val first = pts.first()
        val last = pts.last()
        if (first.y > minY + h * 0.35f || last.y < maxY - h * 0.35f) return "not top->bottom" // top -> bottom
        if (first.x < minX + w * 0.35f || last.x > maxX - w * 0.35f) return "not right->left" // right -> left

        // Mostly downwards.
        var up = 0f
        for (i in 1 until pts.size) {
            val d = pts[i].y - pts[i - 1].y
            if (d < 0) up -= d
        }
        if (up > h * 0.5f) return "too much upward movement"

        // Horizontal sweeps (-1 left, +1 right), ignoring wobbles under a quarter of the width.
        val t = w * 0.25f
        val sweeps = ArrayList<Int>()
        var dir = 0
        var ext = first.x
        for (p in pts) {
            when (dir) {
                0 -> if (p.x < ext - t) { dir = -1; sweeps += -1; ext = p.x }
                     else if (p.x > ext + t) { dir = 1; sweeps += 1; ext = p.x }
                -1 -> if (p.x < ext) ext = p.x
                      else if (p.x > ext + t) { dir = 1; sweeps += 1; ext = p.x }
                else -> if (p.x > ext) ext = p.x
                        else if (p.x < ext - t) { dir = -1; sweeps += -1; ext = p.x }
            }
        }
        // left-right-left, or with a small hook to the right at the start.
        return if (sweeps == listOf(-1, 1, -1) || sweeps == listOf(1, -1, 1, -1)) null else "sweeps=$sweeps"
    }
}

/**
 * Lock-screen part of SOS: an invisible strip at the top of the lock screen (clock area) where
 * the "S" is drawn, and the calls (each contact in turn, [ROUNDS] times through the
 * list, until one answers).
 */
class SosController(private val service: AccessibilityService) {

    companion object {
        private const val TAG = "Sos"
        private const val CHANNEL = "sos"
        private const val NOTIFICATION_ID = 7301

        /** How many times the whole list is tried. */
        private const val ROUNDS = 2

        /** Call never started (no signal, blocked…): try the next contact. */
        private const val NO_CALL_TIMEOUT_MS = 20_000L

        /** Wait after a call ends for the call log to be written. */
        private const val CALL_LOG_DELAY_MS = 2500L

        private const val SYSTEM_UI = "com.android.systemui"
    }

    private val handler = Handler(Looper.getMainLooper())
    private val wm = service.getSystemService(WindowManager::class.java)
    private val keyguard = service.getSystemService(KeyguardManager::class.java)
    private val power = service.getSystemService(PowerManager::class.java)
    private val telephony = service.getSystemService(TelephonyManager::class.java)

    private var strip: View? = null

    /** App shown over the lock screen (alarm, call screen…); null/System UI = the lock screen itself. */
    private var windowPkg: String? = null

    // Calling.
    private var queue: List<Sos.Contact> = emptyList()
    private var next = 0
    private var current: Sos.Contact? = null
    private var callStartedAt = 0L
    private var waitingForCall = false
    private var sawOffhook = false
    private var callListener: Any? = null

    val isActive get() = queue.isNotEmpty()

    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            stop()
        }
    }

    init {
        val filter = IntentFilter(Sos.ACTION_STOP)
        if (Build.VERSION.SDK_INT >= 33) {
            service.registerReceiver(stopReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            // Android 10-12: dynamic receivers are exported. Only senders holding our
            // signature permission (= Abhi Utility itself) may stop an emergency call.
            service.registerReceiver(stopReceiver, filter, Sos.STOP_PERMISSION, null)
        }
        refresh()
    }

    // ---- Lock screen strip -------------------------------------------------------------

    fun onScreenOn(pkg: String?) {
        windowPkg = pkg
        refresh()
    }

    fun onScreenOff() {
        windowPkg = null
        hideStrip()
    }

    fun onWindowChanged(pkg: String) {
        if (pkg == service.packageName) return // our own overlays
        windowPkg = pkg
        refresh()
    }

    /** Shows the strip only on the plain lock screen (not over a call or alarm) while SOS is set up. */
    fun refresh() {
        val onLockScreen = power.isInteractive && keyguard.isKeyguardLocked &&
            (windowPkg == null || windowPkg == SYSTEM_UI)
        if (onLockScreen && !isActive && !inCall() && Sos.ready(service)) showStrip() else hideStrip()
    }

    private fun inCall() = try {
        @Suppress("DEPRECATION")
        telephony.callState != TelephonyManager.CALL_STATE_IDLE
    } catch (_: SecurityException) {
        false
    }

    private fun dp(v: Float) =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, service.resources.displayMetrics)

    private fun showStrip() {
        if (strip != null) return
        val screenH = service.resources.displayMetrics.heightPixels
        val view = DrawView()
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            (screenH * 0.24f).toInt(),
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP
            // Upper part of the lock screen (around the clock): no buttons there. The
            // PIN/pattern pad and the notifications below stay free to touch.
            y = (screenH * 0.06f).toInt()
        }
        try {
            wm.addView(view, params)
            strip = view
        } catch (e: Exception) {
            Log.w(TAG, "Could not show SOS strip", e)
        }
    }

    private fun hideStrip() {
        strip?.let {
            try {
                wm.removeView(it)
            } catch (_: Exception) {
            }
        }
        strip = null
    }

    /** Invisible area that draws a faint trail and checks the stroke for an "S". */
    private inner class DrawView : View(service) {
        private val pts = ArrayList<PointF>()
        private val path = Path()
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(110, 255, 255, 255)
            style = Paint.Style.STROKE
            strokeWidth = dp(5f)
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }

        private fun add(x: Float, y: Float) {
            pts += PointF(x, y)
            path.lineTo(x, y)
        }

        private fun clear() {
            pts.clear()
            path.reset()
        }

        override fun onTouchEvent(e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    Log.d(TAG, "stroke started on the SOS strip")
                    clear()
                    path.moveTo(e.x, e.y)
                    pts += PointF(e.x, e.y)
                }
                MotionEvent.ACTION_MOVE -> {
                    for (i in 0 until e.historySize) add(e.getHistoricalX(i), e.getHistoricalY(i))
                    add(e.x, e.y)
                }
                MotionEvent.ACTION_UP -> {
                    val why = Sos.whyNotS(pts, dp(80f))
                    Log.d(TAG, "stroke on lock screen: ${why ?: "S recognised"}")
                    val isS = why == null
                    clear()
                    if (isS) trigger()
                }
                // A second finger or a cancelled touch: not an S.
                else -> clear()
            }
            invalidate()
            return true
        }

        override fun onDraw(canvas: Canvas) {
            canvas.drawPath(path, paint)
        }
    }

    // ---- Calling -----------------------------------------------------------------------

    /** Starts calling the SOS contacts in turn. */
    fun trigger() {
        if (isActive) return
        val list = Sos.contacts(service)
        if (list.isEmpty() || Sos.missingPermissions(service).isNotEmpty()) return
        Log.d(TAG, "SOS triggered, ${list.size} contacts")
        vibrate()
        queue = list
        next = 0
        hideStrip()
        listenCalls(true)
        callNext()
    }

    /** Stops calling (notification button or the SOS page). */
    fun stop() {
        finish()
        notificationManager().cancel(NOTIFICATION_ID)
    }

    private fun finish() {
        handler.removeCallbacks(noCallTimeout)
        handler.removeCallbacks(checkAnswered)
        queue = emptyList()
        current = null
        waitingForCall = false
        listenCalls(false)
        refresh()
    }

    private fun callNext() {
        handler.removeCallbacks(noCallTimeout)
        if (next >= queue.size * ROUNDS) {
            val help = Sos.wantsNoAnswerHelp(service)
            notify(
                "SOS: no one answered",
                if (help) "Sending your location and recording to your SOS contacts." else "Called every SOS contact $ROUNDS times.",
                ongoing = false
            )
            finish()
            if (help) SosRecordActivity.start(service)
            return
        }
        val c = queue[next % queue.size]
        val position = next % queue.size + 1
        next++
        current = c
        sawOffhook = false
        waitingForCall = true
        callStartedAt = System.currentTimeMillis()
        notify("SOS: calling ${c.label}", "Contact $position of ${queue.size}. Tap Stop to end SOS.", ongoing = true)
        try {
            service.startActivity(
                Intent(Intent.ACTION_CALL, Uri.fromParts("tel", c.number, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            handler.postDelayed(noCallTimeout, NO_CALL_TIMEOUT_MS)
        } catch (e: Exception) {
            Log.w(TAG, "Could not call ${c.number}", e)
            handler.postDelayed({ if (isActive) callNext() }, 1000)
        }
    }

    private val noCallTimeout = Runnable { if (isActive && waitingForCall && !sawOffhook) callNext() }

    private val checkAnswered = Runnable {
        if (!isActive) return@Runnable
        if (lastCallAnswered()) {
            notify("SOS: ${current?.label ?: "a contact"} answered", "SOS calls stopped.", ongoing = false)
            finish()
        } else {
            callNext()
        }
    }

    private fun onCallState(state: Int) {
        if (!isActive || !waitingForCall) return
        when (state) {
            TelephonyManager.CALL_STATE_OFFHOOK -> {
                sawOffhook = true
                handler.removeCallbacks(noCallTimeout)
            }
            TelephonyManager.CALL_STATE_IDLE -> if (sawOffhook) {
                waitingForCall = false
                handler.postDelayed(checkAnswered, CALL_LOG_DELAY_MS)
            }
        }
    }

    /** The call log has the talk time: more than 0 seconds means someone picked up. */
    private fun lastCallAnswered(): Boolean = try {
        service.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(CallLog.Calls.DURATION),
            "${CallLog.Calls.TYPE} = ? AND ${CallLog.Calls.DATE} >= ?",
            arrayOf(CallLog.Calls.OUTGOING_TYPE.toString(), (callStartedAt - 10_000).toString()),
            "${CallLog.Calls.DATE} DESC"
        )?.use { it.moveToFirst() && it.getLong(0) > 0 } ?: false
    } catch (e: Exception) {
        Log.w(TAG, "Could not read the call log", e)
        false // keep calling: better one call too many than none
    }

    private fun listenCalls(on: Boolean) {
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                if (on && callListener == null) {
                    val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                        override fun onCallStateChanged(state: Int) = onCallState(state)
                    }
                    telephony.registerTelephonyCallback(service.mainExecutor, cb)
                    callListener = cb
                } else if (!on) {
                    (callListener as? TelephonyCallback)?.let { telephony.unregisterTelephonyCallback(it) }
                    callListener = null
                }
            } else {
                @Suppress("DEPRECATION")
                if (on && callListener == null) {
                    val l = object : PhoneStateListener() {
                        @Deprecated("Deprecated in Java")
                        override fun onCallStateChanged(state: Int, phoneNumber: String?) = onCallState(state)
                    }
                    telephony.listen(l, PhoneStateListener.LISTEN_CALL_STATE)
                    callListener = l
                } else if (!on) {
                    (callListener as? PhoneStateListener)?.let { telephony.listen(it, PhoneStateListener.LISTEN_NONE) }
                    callListener = null
                }
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "No phone state permission", e)
        }
    }

    // ---- Feedback ----------------------------------------------------------------------

    private fun vibrate() {
        try {
            val v = if (Build.VERSION.SDK_INT >= 31) {
                service.getSystemService(VibratorManager::class.java).defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                service.getSystemService(Vibrator::class.java)
            }
            v.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 400, 150, 400), -1))
        } catch (e: Exception) {
            Log.w(TAG, "Could not vibrate", e)
        }
    }

    private fun notificationManager() = service.getSystemService(NotificationManager::class.java)

    private fun notify(title: String, text: String, ongoing: Boolean) {
        try {
            val nm = notificationManager()
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "SOS", NotificationManager.IMPORTANCE_HIGH)
            )
            val stop = PendingIntent.getBroadcast(
                service, 0, Intent(Sos.ACTION_STOP).setPackage(service.packageName),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val b = Notification.Builder(service, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_phone_call)
                .setContentTitle(title)
                .setContentText(text)
                .setOngoing(ongoing)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
            if (ongoing) b.addAction(Notification.Action.Builder(null, "Stop SOS", stop).build())
            nm.notify(NOTIFICATION_ID, b.build())
        } catch (e: Exception) {
            Log.w(TAG, "Could not post SOS notification", e)
        }
    }

    fun destroy() {
        stop()
        hideStrip()
        try {
            service.unregisterReceiver(stopReceiver)
        } catch (_: Exception) {
        }
    }
}
