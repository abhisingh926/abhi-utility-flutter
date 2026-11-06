package com.abhi.abhi_utility

import android.app.Activity
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import org.json.JSONArray

/**
 * Video / image downloads through Android's DownloadManager: progress
 * notification, resumes after network drops, saved to Downloads/AbhiUtility
 * (shown in the Gallery).
 */
object Downloads {
    private const val PREFS = "downloads"
    private const val KEY_IDS = "ids"
    private const val FOLDER = "AbhiUtility"

    private const val KEY_BUBBLE = "bubble_enabled"

    /** The floating ⬇ button shown while a video plays in a browser / social app. */
    fun bubbleEnabled(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_BUBBLE, true)

    fun setBubbleEnabled(c: Context, on: Boolean) {
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_BUBBLE, on).apply()
    }

    private fun manager(c: Context) = c.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

    private fun ids(c: Context): MutableList<Long> {
        val raw = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_IDS, "[]")!!
        val arr = JSONArray(raw)
        return MutableList(arr.length()) { arr.getLong(it) }
    }

    private fun saveIds(c: Context, ids: List<Long>) {
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_IDS, JSONArray(ids.takeLast(100)).toString()).apply()
    }

    /** Starts a download; returns its id. */
    fun start(
        c: Context,
        url: String,
        fileName: String,
        mimeType: String?,
        referer: String?,
        userAgent: String?,
        cookie: String? = null,
    ): Long {
        val safeName = fileName.replace(Regex("""[\\/:*?"<>|\n\r\t]"""), "_").take(120)
        val req = DownloadManager.Request(Uri.parse(url))
            .setTitle(safeName)
            .setDescription("Abhi Utility download")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, "$FOLDER/$safeName")
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(true)
        if (!mimeType.isNullOrBlank()) req.setMimeType(mimeType)
        if (!referer.isNullOrBlank()) req.addRequestHeader("Referer", referer)
        if (!userAgent.isNullOrBlank()) req.addRequestHeader("User-Agent", userAgent)
        if (!cookie.isNullOrBlank()) req.addRequestHeader("Cookie", cookie) // logged-in sites
        val id = manager(c).enqueue(req)
        saveIds(c, ids(c) + id)
        return id
    }

    /** Our downloads, newest first, with progress. */
    fun list(c: Context): List<Map<String, Any?>> {
        val ids = ids(c)
        if (ids.isEmpty()) return emptyList()
        val out = ArrayList<Map<String, Any?>>()
        val alive = ArrayList<Long>()
        manager(c).query(DownloadManager.Query().setFilterById(*ids.toLongArray()))?.use { cur ->
            val iId = cur.getColumnIndexOrThrow(DownloadManager.COLUMN_ID)
            val iTitle = cur.getColumnIndexOrThrow(DownloadManager.COLUMN_TITLE)
            val iStatus = cur.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)
            val iDone = cur.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
            val iTotal = cur.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
            val iMime = cur.getColumnIndexOrThrow(DownloadManager.COLUMN_MEDIA_TYPE)
            val iTime = cur.getColumnIndexOrThrow(DownloadManager.COLUMN_LAST_MODIFIED_TIMESTAMP)
            val iReason = cur.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)
            while (cur.moveToNext()) {
                val status = when (cur.getInt(iStatus)) {
                    DownloadManager.STATUS_SUCCESSFUL -> "done"
                    DownloadManager.STATUS_FAILED -> "failed"
                    DownloadManager.STATUS_PAUSED -> "paused"
                    DownloadManager.STATUS_PENDING -> "pending"
                    else -> "running"
                }
                alive += cur.getLong(iId)
                out += mapOf(
                    "id" to cur.getLong(iId),
                    "title" to cur.getString(iTitle),
                    "status" to status,
                    "bytes" to cur.getLong(iDone),
                    "total" to cur.getLong(iTotal),
                    "mime" to cur.getString(iMime),
                    "time" to cur.getLong(iTime),
                    "reason" to cur.getInt(iReason),
                )
            }
        }
        // Forget downloads the user removed in the system Downloads app.
        if (alive.size != ids.size) saveIds(c, ids.filter { it in alive })
        return out.sortedByDescending { it["time"] as Long }
    }

    private fun fileUri(c: Context, id: Long): Uri? = manager(c).getUriForDownloadedFile(id)

    fun open(a: Activity, id: Long, mime: String?) {
        val uri = fileUri(a, id) ?: throw IllegalStateException("The file is not available")
        a.startActivity(
            Intent.createChooser(
                Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime ?: a.contentResolver.getType(uri))
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                "Open with",
            )
        )
    }

    fun share(a: Activity, id: Long, mime: String?) {
        val uri = fileUri(a, id) ?: throw IllegalStateException("The file is not available")
        a.startActivity(
            Intent.createChooser(
                Intent(Intent.ACTION_SEND).setType(mime ?: "*/*").putExtra(Intent.EXTRA_STREAM, uri)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                "Share",
            )
        )
    }

    /** Cancels a running download, or deletes the downloaded file. */
    fun remove(c: Context, id: Long) {
        manager(c).remove(id)
        saveIds(c, ids(c).filter { it != id })
    }
}
