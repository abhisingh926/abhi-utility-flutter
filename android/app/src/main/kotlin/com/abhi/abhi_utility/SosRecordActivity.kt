package com.abhi.abhi_utility

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.View
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.camera.core.CameraSelector
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import java.io.File
import java.util.Locale

/**
 * SOS, after no contact answered. Shown over the lock screen but looks like the screen
 * is off: all black, lowest brightness, no status bar, touches and Back ignored. So
 * whoever holds the phone doesn't see that it records. It still counts as an app on
 * screen, which Android requires for using the camera, microphone and location (a
 * background service may not). Android's own camera / mic privacy dot can still show
 * in the corner; apps can't hide that. Pressing the power button ends it early (what
 * was recorded so far is kept and sent).
 *
 *  1. Finds the current location and texts it to every SOS contact.
 *  2. Records [Sos.RECORD_SECONDS] of video with sound.
 *  3. Hands the video to [SosUpload], which uploads it and texts the link.
 */
class SosRecordActivity : ComponentActivity() {

    companion object {
        private const val TAG = "SosRecord"
        private const val EXTRA_STARTED = "startedAt"

        /** Debug builds only: record without texting or uploading (for testing). */
        private const val EXTRA_DRY_RUN = "dryRun"

        /** Wait this long for a good location fix, then use the best one so far. */
        private const val LOCATION_TIMEOUT_MS = 20_000L

        /** A fix this accurate (metres) is good enough to send at once. */
        private const val GOOD_ACCURACY_M = 50f

        fun start(c: Context) {
            try {
                c.startActivity(
                    Intent(c, SosRecordActivity::class.java)
                        .putExtra(EXTRA_STARTED, System.currentTimeMillis())
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                )
            } catch (e: Exception) {
                Log.w(TAG, "Could not open the SOS screen", e)
            }
        }

        /** Google Maps link for the SMS. */
        fun mapsLink(l: Location) =
            String.format(Locale.US, "https://maps.google.com/?q=%.6f,%.6f", l.latitude, l.longitude)
    }

    private val handler = Handler(Looper.getMainLooper())
    private val dryRun get() =
        (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0 && intent.getBooleanExtra(EXTRA_DRY_RUN, false)

    private var started = false
    private var location: Location? = null
    private var locationDone = false
    private var listener: LocationListener? = null
    private var recording: Recording? = null
    private var recordStartedAt = 0L
    private var videoFile: File? = null
    private var recordDone = false
    private var handedOver = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        buildUi()
        if (savedInstanceState == null) begin()
    }

    // ---- UI: a "switched off" screen -----------------------------------------------------

    private fun buildUi() {
        window.setBackgroundDrawable(ColorDrawable(Color.BLACK))
        window.attributes = window.attributes.apply { screenBrightness = 0f } // dimmest
        setContentView(View(this).apply { setBackgroundColor(Color.BLACK) })
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    // Touches land on this black screen and do nothing; Back does nothing while it records.
    @Deprecated("Back is ignored on purpose")
    @Suppress("DEPRECATION", "MissingSuperCall")
    override fun onBackPressed() {
        if (handedOver) super.onBackPressed()
    }

    /** Progress goes to the log only: nothing on screen. */
    private fun setStatus(text: String) {
        Log.d(TAG, text)
    }

    // ---- Flow -----------------------------------------------------------------------------

    private fun begin() {
        if (started) return
        started = true
        val wantsVideo = Sos.record(this) && Sos.has(this, Manifest.permission.CAMERA) && Sos.upload(this) != null
        setStatus("No one answered. Getting your location…")
        // Location and video start together: the recording doesn't wait for GPS.
        findLocation()
        if (wantsVideo) startRecording() else recordDone = true
    }

    /** Location found (or timed out): text it, and continue. */
    private fun onLocationDone() {
        if (locationDone) return
        locationDone = true
        stopLocation()
        if (Sos.smsLocation(this) && !dryRun) {
            val l = location
            val text = if (l != null) {
                "${Sos.smsOpening(this)} I called you but no one answered. My location: ${mapsLink(l)}" +
                    (if (l.hasAccuracy()) " (within ${l.accuracy.toInt()} m)" else "")
            } else {
                "${Sos.smsOpening(this)} I called you but no one answered. My location could not be found."
            }
            val sent = Sos.smsAll(this, text)
            setStatus(if (sent > 0) "Location sent to $sent SOS contact(s)." else "Could not send SMS.")
        }
        maybeHandOver()
    }

    /** Both done: upload (in a service, so it continues if this screen closes). */
    private fun maybeHandOver() {
        if (!locationDone || !recordDone || handedOver) return
        handedOver = true
        val file = videoFile
        if (file != null && file.exists() && file.length() > 0) {
            if (dryRun) {
                setStatus("Dry run: recorded ${file.length()} bytes to $file (not uploaded)")
                handler.postDelayed({ finish() }, 500)
                return
            }
            SosUpload.start(this, file, location)
            setStatus("Uploading the recording. The link will be texted to your SOS contacts.")
        }
        handler.postDelayed({ finish() }, 500)
    }

    // ---- Location -------------------------------------------------------------------------

    @SuppressLint("MissingPermission")
    private fun findLocation() {
        val lm = getSystemService(LocationManager::class.java)
        val allowed = Sos.has(this, Manifest.permission.ACCESS_FINE_LOCATION) ||
            Sos.has(this, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (lm == null || !allowed) {
            onLocationDone()
            return
        }
        // Recent last-known fix as a fallback.
        for (p in lm.getProviders(true)) {
            try {
                lm.getLastKnownLocation(p)?.let { offer(it, fresh = false) }
            } catch (_: Exception) {
            }
        }
        val l = LocationListener { offer(it, fresh = true) }
        listener = l
        val providers = lm.getProviders(true).filter { it != LocationManager.PASSIVE_PROVIDER }
        for (p in providers) {
            try {
                lm.requestLocationUpdates(p, 1000L, 0f, l, Looper.getMainLooper())
            } catch (e: Exception) {
                Log.w(TAG, "No updates from $p", e)
            }
        }
        if (providers.isEmpty()) onLocationDone() // location is turned off: send what we have
        else handler.postDelayed({ onLocationDone() }, LOCATION_TIMEOUT_MS)
    }

    private fun offer(l: Location, fresh: Boolean) {
        if (locationDone) return
        val ageMs = (SystemClock.elapsedRealtimeNanos() - l.elapsedRealtimeNanos) / 1_000_000
        if (!fresh && ageMs > 10 * 60_000) return // older than 10 minutes: not useful
        val best = location
        if (best == null || !best.hasAccuracy() || (l.hasAccuracy() && l.accuracy < best.accuracy)) location = l
        if (fresh && l.hasAccuracy() && l.accuracy <= GOOD_ACCURACY_M) onLocationDone()
    }

    private fun stopLocation() {
        listener?.let {
            try {
                getSystemService(LocationManager::class.java)?.removeUpdates(it)
            } catch (_: Exception) {
            }
        }
        listener = null
    }

    // ---- Video ----------------------------------------------------------------------------

    @SuppressLint("MissingPermission") // RECORD_AUDIO is checked before withAudioEnabled()
    private fun startRecording() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            try {
                val provider = future.get()
                val recorder = Recorder.Builder()
                    .setQualitySelector(
                        // ~480p keeps 30 s at a few MB: quick to upload on a weak connection.
                        QualitySelector.from(Quality.SD, FallbackStrategy.higherQualityOrLowerThan(Quality.SD))
                    )
                    .build()
                val capture = VideoCapture.withOutput(recorder)
                val camera = when {
                    provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA) -> CameraSelector.DEFAULT_BACK_CAMERA
                    else -> CameraSelector.DEFAULT_FRONT_CAMERA
                }
                provider.unbindAll()
                provider.bindToLifecycle(this, camera, capture) // no preview: nothing on screen

                val dir = File(filesDir, "sos").apply { mkdirs() }
                val file = File(dir, "sos-${System.currentTimeMillis()}.mp4")
                videoFile = file
                var pending = capture.output.prepareRecording(this, FileOutputOptions.Builder(file).build())
                if (Sos.has(this, Manifest.permission.RECORD_AUDIO)) pending = pending.withAudioEnabled()
                recording = pending.start(mainExecutor) { event ->
                    when (event) {
                        is VideoRecordEvent.Start -> {
                            recordStartedAt = SystemClock.elapsedRealtime()
                            handler.postDelayed({ recording?.stop() }, Sos.RECORD_SECONDS * 1000L)
                        }
                        is VideoRecordEvent.Finalize -> {
                            if (event.hasError()) Log.w(TAG, "Recording ended with error ${event.error}", event.cause)
                            recording = null
                            recordDone = true
                            setStatus("Recording finished.")
                            try {
                                provider.unbindAll()
                            } catch (_: Exception) {
                            }
                            maybeHandOver()
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Could not record", e)
                setStatus("Could not start the camera.")
                recordDone = true
                maybeHandOver()
            }
        }, mainExecutor)
    }

    override fun onDestroy() {
        stopLocation()
        // Closed early (e.g. screen turned off): keep what was recorded.
        recording?.stop()
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}
