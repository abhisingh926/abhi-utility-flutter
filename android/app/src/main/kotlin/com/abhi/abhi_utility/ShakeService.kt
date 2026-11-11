package com.abhi.abhi_utility

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import kotlin.math.sqrt

/**
 * Foreground service that keeps listening for shakes after the app is closed
 * and toggles the flashlight on each shake.
 */
class ShakeService : Service(), SensorEventListener {

    companion object {
        const val ACTION_STOP = "com.abhi.abhi_utility.STOP"
        private const val CHANNEL_ID = "shake_torch"
        private const val NOTIFICATION_ID = 1
        /** Linear acceleration (gravity removed, m/s²) that counts as one jerk. */
        private const val JERK_THRESHOLD = 12f

        /** Back-and-forth jerks, alternating direction, that make one shake. */
        private const val JERKS_NEEDED = 3

        /** Ignore readings this soon after a jerk (one jerk spans several samples). */
        private const val MIN_JERK_GAP_MS = 70L

        /** If the next jerk takes longer than this, start counting again. */
        private const val MAX_JERK_GAP_MS = 400L

        private const val COOLDOWN_MS = 1500L

        /** Motion samples may be delivered up to this late, in batches (saves battery). */
        private const val MAX_BATCH_US = 300_000
        private const val TAG = "ShakeService"

        @Volatile
        var isRunning = false
            private set
    }

    private lateinit var sensorManager: SensorManager
    private lateinit var cameraManager: CameraManager
    private var cameraId: String? = null
    private var torchOn = false
    private var lastShake = 0L
    private var wakeLock: PowerManager.WakeLock? = null

    // Shake pattern tracking.
    private var linearSensor = false
    private val gravity = FloatArray(3)
    private var jerkCount = 0
    private var lastJerkTime = 0L
    private val lastJerk = FloatArray(3)

    // Proximity: true when something covers the top of the phone (pocket, bag, face-down).
    private var proximityCovered = false
    private var proximityMax = 0f

    private val torchCallback = object : CameraManager.TorchCallback() {
        override fun onTorchModeChanged(id: String, enabled: Boolean) {
            if (id == cameraId) torchOn = enabled
        }
    }

    override fun onCreate() {
        super.onCreate()
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        cameraId = findFlashCamera(cameraManager)
        cameraManager.registerTorchCallback(torchCallback, null)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // Remember "off", so opening the app doesn't turn shake back on.
            // Same store/key the Flutter side reads (shared_preferences: "flutter." prefix).
            getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
                .putBoolean("flutter.shake_enabled", false).apply()
            stopSelf()
            return START_NOT_STICKY
        }

        startAsForeground()

        if (!isRunning) {
            // Prefer linear acceleration (gravity already removed); otherwise filter it ourselves.
            // Prefer the "wake-up" variant: it wakes the CPU itself when it has data,
            // so no wake lock is needed while the screen is off.
            val motion = sensorManager.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION, true)
                ?.also { linearSensor = true }
                ?: sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER, true)
                    ?.also { linearSensor = false }
                ?: sensorManager.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
                    ?.also { linearSensor = true }
                ?: sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
                    ?.also { linearSensor = false }
            // Samples are batched for up to 300 ms: with the screen off the CPU then wakes a
            // few times a second instead of for every sample (~50/s). A shake lasts longer
            // than that, so it is still caught, at most ~0.3 s later.
            motion?.let { sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME, MAX_BATCH_US) }
            sensorManager.getDefaultSensor(Sensor.TYPE_PROXIMITY)?.let {
                proximityMax = it.maximumRange
                sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
            }
            // Only phones without a wake-up motion sensor need a wake lock, and only
            // while the screen is off (with the screen on the CPU is awake anyway).
            if (motion != null && !motion.isWakeUpSensor) {
                registerReceiver(screenReceiver, IntentFilter().apply {
                    addAction(Intent.ACTION_SCREEN_OFF)
                    addAction(Intent.ACTION_SCREEN_ON)
                })
                screenReceiverOn = true
                if (!(getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive) holdWakeLock(true)
            }
            isRunning = true
        }
        // Ask Android to restart the service if it gets killed.
        return START_STICKY
    }

    private fun startAsForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Shake flashlight", NotificationManager.IMPORTANCE_LOW)
            )
        }

        val openApp = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, ShakeService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)

        val notification = builder
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentTitle("Abhi Utility")
            .setContentText("Shake to toggle the flashlight")
            .setContentIntent(openApp)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_PROXIMITY -> {
                // Most phones report 0 when covered and maximumRange when clear.
                proximityCovered = event.values[0] < proximityMax && event.values[0] < 5f
                Log.d(TAG, "proximity=${event.values[0]} covered=$proximityCovered")
                if (proximityCovered) resetJerks()
            }
            else -> onMotion(event.values, event.timestamp / 1_000_000)
        }
    }

    /**
     * A real shake is several strong jerks back and forth in quick succession.
     * A drop on the bed or a bump in a pocket is a single jolt (plus a weaker
     * bounce), so it never reaches [JERKS_NEEDED].
     */
    private fun onMotion(values: FloatArray, sampleMs: Long) {
        val a = FloatArray(3)
        if (linearSensor) {
            values.copyInto(a, endIndex = 3)
        } else {
            // High-pass filter: estimate gravity with a low-pass filter and subtract it.
            for (i in 0..2) {
                gravity[i] = 0.8f * gravity[i] + 0.2f * values[i]
                a[i] = values[i] - gravity[i]
            }
        }

        // When the sample was taken (same clock as elapsedRealtime). Samples arrive in
        // batches (MAX_BATCH_US), so the time they arrive says nothing about the gaps.
        val now = sampleMs
        if (proximityCovered || now - lastShake < COOLDOWN_MS) return
        if (jerkCount > 0 && now - lastJerkTime > MAX_JERK_GAP_MS) resetJerks()

        val strength = sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])
        if (strength < JERK_THRESHOLD) return
        if (now - lastJerkTime < MIN_JERK_GAP_MS) return

        // A reversal points more than 90° away from the previous jerk.
        val dot = a[0] * lastJerk[0] + a[1] * lastJerk[1] + a[2] * lastJerk[2]
        if (jerkCount > 0 && dot >= 0) return // same direction: not back-and-forth

        jerkCount++
        a.copyInto(lastJerk)
        lastJerkTime = now
        Log.d(TAG, "jerk #$jerkCount strength=%.1f".format(strength))

        if (jerkCount >= JERKS_NEEDED) {
            lastShake = now
            resetJerks()
            toggleTorch()
        }
    }

    private fun resetJerks() {
        jerkCount = 0
        lastJerk.fill(0f)
    }

    private fun toggleTorch() {
        val id = cameraId ?: return
        try {
            cameraManager.setTorchMode(id, !torchOn)
        } catch (e: Exception) {
            // Happens e.g. when another app is using the camera.
            Log.w(TAG, "Could not toggle torch", e)
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    /** Screen off -> keep the CPU awake for the sensor; screen on -> let go. */
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            holdWakeLock(intent.action == Intent.ACTION_SCREEN_OFF)
        }
    }
    private var screenReceiverOn = false

    private fun holdWakeLock(hold: Boolean) {
        if (hold) {
            if (wakeLock?.isHeld == true) return
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "AbhiUtility:shake").apply {
                setReferenceCounted(false)
                acquire()
            }
        } else {
            wakeLock?.let { if (it.isHeld) it.release() }
        }
    }

    override fun onDestroy() {
        sensorManager.unregisterListener(this)
        cameraManager.unregisterTorchCallback(torchCallback)
        if (screenReceiverOn) unregisterReceiver(screenReceiver)
        holdWakeLock(false)
        isRunning = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

fun findFlashCamera(cm: CameraManager): String? = cm.cameraIdList.firstOrNull { id ->
    val c = cm.getCameraCharacteristics(id)
    c.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true &&
        c.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
} ?: cm.cameraIdList.firstOrNull { id ->
    cm.getCameraCharacteristics(id).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
}
