package com.abhi.abhi_utility

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore

/**
 * Saves PDFs to Downloads/AbhiUtility (MediaStore, no storage permission needed)
 * and opens / shares them with other apps.
 */
object PdfFiles {
    private const val FOLDER = "AbhiUtility"

    /** Writes [bytes] as [name].pdf and returns its content:// uri. */
    fun save(activity: Activity, bytes: ByteArray, name: String): String {
        val resolver = activity.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, if (name.endsWith(".pdf")) name else "$name.pdf")
            put(MediaStore.Downloads.MIME_TYPE, "application/pdf")
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Could not create the file")
        try {
            resolver.openOutputStream(uri)!!.use { it.write(bytes) }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return uri.toString()
    }

    /**
     * Copies a content:// (or file://) PDF into the app cache so the viewer can open
     * it by path. Returns the local file path.
     */
    fun copyToCache(context: android.content.Context, uriString: String): String {
        val uri = Uri.parse(uriString)
        var name = "document.pdf"
        context.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst() && !c.isNull(0)) name = c.getString(0) }
        name = name.replace(Regex("""[\\/:*?"<>|]"""), "_")
        if (!name.lowercase().endsWith(".pdf")) name += ".pdf"
        // A folder per copy so two files with the same name don't overwrite each other.
        val dir = java.io.File(context.cacheDir, "pdf_open/${System.currentTimeMillis()}").apply { mkdirs() }
        val out = java.io.File(dir, name)
        context.contentResolver.openInputStream(uri)!!.use { input ->
            out.outputStream().use { input.copyTo(it) }
        }
        return out.absolutePath
    }

    /** True if the file still exists (the user may have deleted it). */
    fun exists(activity: Activity, uri: String): Boolean = try {
        activity.contentResolver.openFileDescriptor(Uri.parse(uri), "r")?.use { true } ?: false
    } catch (_: Exception) {
        false
    }

    fun open(activity: Activity, uri: String) {
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(Uri.parse(uri), "application/pdf")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        activity.startActivity(Intent.createChooser(intent, "Open PDF with"))
    }

    fun share(activity: Activity, uri: String) {
        val intent = Intent(Intent.ACTION_SEND)
            .setType("application/pdf")
            .putExtra(Intent.EXTRA_STREAM, Uri.parse(uri))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        activity.startActivity(Intent.createChooser(intent, "Share PDF"))
    }
}
