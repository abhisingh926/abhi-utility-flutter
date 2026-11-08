package com.abhi.abhi_utility

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import java.io.File
import java.util.Locale

/**
 * SOS, after no contact answered: shown over the lock screen (an app on screen may use
 * the camera, microphone and location, a background service may not).
 *
 *  1. Finds the current location and texts it to every SOS contact.
 *  2. Records [Sos.RECORD_SECONDS] of video with sound.
 *  3. Hands the video to [SosUpload], which uploads it and texts the link.
 */
class SosRecordActivity : ComponentActivity() {

    companion object {
        private const val TAG = "SosRecord"
        private const val EXTRA_STARTED = "startedAt"

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
    private lateinit var status: TextView
    private lateinit var timer: TextView
    private lateinit var preview: PreviewView

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

    // ---- UI -------------------------------------------------------------------------------

    private fun buildUi() {
        val density = resources.displayMetrics.density
        preview = PreviewView(this).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.argb(200, 183, 28, 28))
            val pad = (20 * density).toInt()
            setPadding(pad, pad * 2, pad, pad)
        }
        TextView(this).apply {
            text = "SOS"
            setTextColor(Color.WHITE)
            textSize = 28f
            typeface = Typeface.DEFAULT_BOLD
            panel.addView(this)
        }
        status = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 17f
            panel.addView(this)
        }
        timer = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 15f
            panel.addView(this)
        }
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        root.addView(preview, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        root.addView(
            panel,
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP)
        )
        setContentView(root)
    }

    private fun setStatus(text: String) {
        status.text = text
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
        if (Sos.smsLocation(this)) {
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
            SosUpload.start(this, file, location)
            setStatus("Uploading the recording. The link will be texted to your SOS contacts.")
        }
        handler.postDelayed({ finish() }, 4000)
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
                val previewUse = Preview.Builder().build().also { it.surfaceProvider = preview.surfaceProvider }
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
                provider.bindToLifecycle(this, camera, previewUse, capture)

                val dir = File(filesDir, "sos").apply { mkdirs() }
                val file = File(dir, "sos-${System.currentTimeMillis()}.mp4")
                videoFile = file
                var pending = capture.output.prepareRecording(this, FileOutputOptions.Builder(file).build())
                if (Sos.has(this, Manifest.permission.RECORD_AUDIO)) pending = pending.withAudioEnabled()
                recording = pending.start(mainExecutor) { event ->
                    when (event) {
                        is VideoRecordEvent.Start -> {
                            recordStartedAt = SystemClock.elapsedRealtime()
                            tick()
                            handler.postDelayed({ recording?.stop() }, Sos.RECORD_SECONDS * 1000L)
                        }
                        is VideoRecordEvent.Finalize -> {
                            if (event.hasError()) Log.w(TAG, "Recording ended with error ${event.error}", event.cause)
                            recording = null
                            recordDone = true
                            timer.text = "Recording finished."
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
                timer.text = "Could not start the camera."
                recordDone = true
                maybeHandOver()
            }
        }, mainExecutor)
    }

    private fun tick() {
        if (recording == null) return
        val left = Sos.RECORD_SECONDS - ((SystemClock.elapsedRealtime() - recordStartedAt) / 1000).toInt()
        timer.text = "● Recording video and sound… ${left.coerceAtLeast(0)} s"
        handler.postDelayed({ tick() }, 500)
    }

    override fun onDestroy() {
        stopLocation()
        // Closed early (e.g. screen turned off): keep what was recorded.
        recording?.stop()
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}
