package com.abhi.abhi_utility

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.location.Location
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Uploads an SOS recording and texts the link to the SOS contacts.
 *
 * Runs on a plain background thread: the app process stays alive while the
 * accessibility service (ReelCounterService) is bound, also with the screen locked.
 *
 *  1. POST /api/v1/sos/alerts { lat, lng, accuracy } -> { token, url }
 *  2. PUT  /api/v1/sos/alerts/<token>/video (the MP4)
 *  3. SMS "… recording: <url>" to every SOS contact
 * Network errors are retried with growing pauses (about 15 minutes in total).
 */
object SosUpload {
    private const val TAG = "SosUpload"
    private const val CHANNEL = "sos"
    private const val NOTIFICATION_ID = 7302
    private val RETRY_DELAYS_S = longArrayOf(10, 20, 40, 60, 120, 240, 480)

    fun start(context: Context, file: File, location: Location?) {
        val c = context.applicationContext
        Thread({ run(c, file, location) }, "sos-upload").start()
    }

    private fun run(c: Context, file: File, location: Location?) {
        val upload = Sos.upload(c)
        if (upload == null) {
            notify(c, "SOS recording saved on this phone", "Log in to Abhi Utility to upload SOS recordings.")
            SosHistory.recording(c, "not_logged_in", file)
            return
        }
        notify(c, "SOS: uploading the recording…", "The link will be texted to your SOS contacts.")
        var token: String? = null
        var url: String? = null
        for (attempt in 0..RETRY_DELAYS_S.size) {
            try {
                if (token == null) {
                    val body = JSONObject()
                    if (location != null) {
                        body.put("lat", location.latitude).put("lng", location.longitude)
                        if (location.hasAccuracy()) body.put("accuracy", location.accuracy.toDouble())
                    }
                    val res = JSONObject(request(upload, "POST", "/api/v1/sos/alerts", "application/json", body.toString().toByteArray()))
                    token = res.getString("token")
                    url = res.getString("url")
                }
                request(upload, "PUT", "/api/v1/sos/alerts/$token/video", "video/mp4", file)
                val sent = Sos.smsAll(c, "${Sos.smsOpening(c)} Video + sound recorded on my phone, and my location: $url")
                notify(c, "SOS recording sent", if (sent > 0) "Link texted to $sent SOS contact(s)." else "Uploaded, but the SMS could not be sent: $url")
                SosHistory.recording(c, "uploaded", url = url, smsSentTo = sent)
                file.delete()
                return
            } catch (e: HttpFail) {
                Log.w(TAG, "Upload refused: ${e.status} ${e.message}")
                if (e.status == 409) { // video already there (an earlier try got through)
                    val sent = Sos.smsAll(c, "${Sos.smsOpening(c)} Video + sound recorded on my phone, and my location: $url")
                    SosHistory.recording(c, "uploaded", url = url, smsSentTo = sent)
                    file.delete()
                    return
                }
                if (e.status in 400..499 && e.status != 408 && e.status != 429) {
                    notify(c, "SOS recording not uploaded", if (e.status == 401) "Open Abhi Utility and turn the SOS recording on again." else "The server refused it (${e.status}).")
                    SosHistory.recording(c, "failed", file, note = if (e.status == 401) "Not uploaded: SOS recording needs to be turned on again." else "Not uploaded: the server refused it (${e.status}).")
                    return // not something a retry fixes; the file stays on the phone
                }
            } catch (e: Exception) {
                Log.w(TAG, "Upload failed (attempt ${attempt + 1})", e)
            }
            if (attempt < RETRY_DELAYS_S.size) Thread.sleep(RETRY_DELAYS_S[attempt] * 1000)
        }
        notify(c, "SOS recording not uploaded", "No internet connection. The recording is saved on this phone.")
        SosHistory.recording(c, "failed", file, note = "Not uploaded: no internet connection.")
    }

    private class HttpFail(val status: Int, message: String) : Exception(message)

    /** Sends [body] (ByteArray or File); returns the response text. */
    private fun request(upload: Sos.Upload, method: String, path: String, type: String, body: Any): String {
        val conn = URL(upload.baseUrl + path).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = method
            conn.connectTimeout = 20_000
            conn.readTimeout = 120_000
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", type)
            conn.setRequestProperty("X-SOS-Key", upload.key)
            when (body) {
                is ByteArray -> {
                    conn.setFixedLengthStreamingMode(body.size)
                    conn.outputStream.use { it.write(body) }
                }
                is File -> {
                    conn.setFixedLengthStreamingMode(body.length())
                    conn.outputStream.use { out -> body.inputStream().use { it.copyTo(out, 64 * 1024) } }
                }
            }
            val code = conn.responseCode
            val text = (if (code >= 400) conn.errorStream else conn.inputStream)?.bufferedReader()?.use { it.readText() } ?: ""
            if (code >= 400) throw HttpFail(code, text.take(200))
            return text
        } finally {
            conn.disconnect()
        }
    }

    private fun notify(c: Context, title: String, text: String) {
        try {
            val nm = c.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "SOS", NotificationManager.IMPORTANCE_HIGH))
            nm.notify(
                NOTIFICATION_ID,
                Notification.Builder(c, CHANNEL)
                    .setSmallIcon(android.R.drawable.stat_sys_upload)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setStyle(Notification.BigTextStyle().bigText(text))
                    .build()
            )
        } catch (e: Exception) {
            Log.w(TAG, "Could not post notification", e)
        }
    }
}
