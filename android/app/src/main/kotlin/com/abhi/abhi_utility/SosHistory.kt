package com.abhi.abhi_utility

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * What happened in each SOS, newest first, kept on this phone (SOS page → History):
 * the calls (who, when, answered or not, how long), the location SMS and the
 * recording (uploaded link, or the file if it never got uploaded).
 *
 * One JSON array in SharedPreferences, at most [MAX_EVENTS]. Steps after the calls
 * (SosRecordActivity, SosUpload) add to the newest event.
 */
object SosHistory {
    private const val TAG = "SosHistory"
    private const val PREFS = "sos_history"
    private const val KEY = "events"
    private const val MAX_EVENTS = 50

    /** A later step belongs to the newest event if it started this recently. */
    private const val ATTACH_WINDOW_MS = 30 * 60_000L

    private val lock = Any()

    private fun prefs(c: Context) = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun load(c: Context): JSONArray = try {
        JSONArray(prefs(c).getString(KEY, "[]"))
    } catch (e: Exception) {
        Log.w(TAG, "History unreadable, starting again", e)
        JSONArray()
    }

    private fun save(c: Context, events: JSONArray) {
        prefs(c).edit().putString(KEY, events.toString()).apply()
    }

    /** Changes the event [id] (or the newest recent one when id is null). */
    private fun update(c: Context, id: Long?, change: (JSONObject) -> Unit) {
        synchronized(lock) {
            val events = load(c)
            for (i in 0 until events.length()) {
                val e = events.getJSONObject(i)
                val match = if (id != null) e.optLong("id") == id
                else i == 0 && System.currentTimeMillis() - e.optLong("startedAt") < ATTACH_WINDOW_MS
                if (match) {
                    change(e)
                    save(c, events)
                    return
                }
                if (id == null) break
            }
            Log.w(TAG, "No SOS event to update (id=$id)")
        }
    }

    /** New SOS (the S was drawn). Returns its id. */
    fun start(c: Context, trigger: String): Long {
        val now = System.currentTimeMillis()
        synchronized(lock) {
            val old = load(c)
            val events = JSONArray().put(
                JSONObject()
                    .put("id", now)
                    .put("startedAt", now)
                    .put("trigger", trigger)
                    .put("outcome", "calling")
                    .put("calls", JSONArray())
            )
            for (i in 0 until minOf(old.length(), MAX_EVENTS - 1)) events.put(old.get(i))
            // Recordings of events that fell off the end aren't listed any more.
            for (i in MAX_EVENTS - 1 until old.length()) {
                old.optJSONObject(i)?.optJSONObject("recording")?.optString("file")?.takeIf { it.isNotEmpty() }
                    ?.let { File(it).delete() }
            }
            save(c, events)
        }
        return now
    }

    /** A call to [contact] was started. */
    fun callStarted(c: Context, id: Long, contact: Sos.Contact) = update(c, id) { e ->
        e.getJSONArray("calls").put(
            JSONObject()
                .put("name", contact.name)
                .put("number", contact.number)
                .put("at", System.currentTimeMillis())
                .put("result", "calling")
        )
    }

    /**
     * Result of the newest call: "answered", "no_answer", "not_connected" (never rang) or
     * "failed" (couldn't dial). [seconds]: time from dialling to hanging up, if known.
     */
    fun callEnded(c: Context, id: Long, result: String, seconds: Int? = null) = update(c, id) { e ->
        val calls = e.getJSONArray("calls")
        if (calls.length() == 0) return@update
        val call = calls.getJSONObject(calls.length() - 1)
        call.put("result", result)
        if (seconds != null) call.put("seconds", seconds)
    }

    /** How the calling ended: "answered", "no_answer" or "stopped" (Stop SOS). */
    fun finished(c: Context, id: Long, outcome: String) = update(c, id) { e ->
        val calls = e.getJSONArray("calls")
        if (calls.length() > 0) {
            val last = calls.getJSONObject(calls.length() - 1)
            if (last.optString("result") == "calling") last.put("result", if (outcome == "stopped") "stopped" else "no_answer")
        }
        e.put("outcome", outcome)
        e.put("endedAt", System.currentTimeMillis())
    }

    /** Location SMS (sentTo = number of contacts it reached; lat/lng null when not found). */
    fun locationSent(c: Context, sentTo: Int, lat: Double?, lng: Double?, accuracyM: Int?) = update(c, null) { e ->
        val loc = JSONObject().put("sentTo", sentTo).put("at", System.currentTimeMillis())
        if (lat != null && lng != null) loc.put("lat", lat).put("lng", lng)
        if (accuracyM != null) loc.put("accuracyM", accuracyM)
        e.put("location", loc)
    }

    /**
     * Recording state: "uploading", "uploaded" (with [url]), "failed" / "not_logged_in"
     * (the [file] stays on the phone), or "no_video" (camera couldn't record).
     */
    fun recording(c: Context, status: String, file: File? = null, url: String? = null, smsSentTo: Int? = null, note: String? = null) =
        update(c, null) { e ->
            val r = e.optJSONObject("recording") ?: JSONObject()
            r.put("status", status).put("at", System.currentTimeMillis())
            if (file != null) r.put("file", file.absolutePath)
            if (status == "uploaded") r.remove("file") // the phone copy is deleted after upload
            if (url != null) r.put("url", url)
            if (smsSentTo != null) r.put("smsSentTo", smsSentTo)
            if (note != null) r.put("note", note) else r.remove("note")
            e.put("recording", r)
        }

    /** Every event, newest first, as plain maps for Flutter (recordings whose file is gone are marked). */
    fun list(c: Context): List<Map<String, Any?>> {
        val events = synchronized(lock) { load(c) }
        return (0 until events.length()).map { i ->
            val e = events.getJSONObject(i)
            e.optJSONObject("recording")?.let { r ->
                val path = r.optString("file")
                r.put("fileExists", path.isNotEmpty() && File(path).exists())
            }
            toMap(e)
        }
    }

    /** Deletes the history and the recordings still kept on the phone. */
    fun clear(c: Context) {
        synchronized(lock) {
            val events = load(c)
            for (i in 0 until events.length()) {
                events.optJSONObject(i)?.optJSONObject("recording")?.optString("file")
                    ?.takeIf { it.isNotEmpty() }?.let { File(it).delete() }
            }
            prefs(c).edit().remove(KEY).apply()
        }
    }

    private fun toMap(o: JSONObject): Map<String, Any?> =
        o.keys().asSequence().associateWith { k -> convert(o.get(k)) }

    private fun convert(v: Any?): Any? = when (v) {
        is JSONObject -> toMap(v)
        is JSONArray -> (0 until v.length()).map { convert(v.get(it)) }
        JSONObject.NULL -> null
        else -> v
    }
}
