package com.abhi.abhi_utility

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Size
import java.io.ByteArrayOutputStream

/**
 * WhatsApp Status Saver. WhatsApp keeps the statuses you've viewed in
 * Android/media/<package>/…/Media/.Statuses. Android only lets other apps read
 * that folder after the user picks it once in the system folder picker
 * (Storage Access Framework); the permission is then kept.
 */
object StatusSaver {
    const val REQUEST_CODE = 4711
    private const val PREFS = "status_saver"
    private const val STORAGE = "com.android.externalstorage.documents"

    private fun folder(business: Boolean) =
        if (business) "Android/media/com.whatsapp.w4b/WhatsApp Business/Media/.Statuses"
        else "Android/media/com.whatsapp/WhatsApp/Media/.Statuses"

    private fun key(business: Boolean) = if (business) "tree_business" else "tree"

    /** System folder picker, opened directly at WhatsApp's status folder. */
    fun pickIntent(business: Boolean): Intent =
        Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            .putExtra(DocumentsContract.EXTRA_INITIAL_URI, DocumentsContract.buildDocumentUri(STORAGE, "primary:${folder(business)}"))
            .addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )

    /**
     * Keeps access to the folder the user picked. Returns false if they picked a
     * different folder than WhatsApp's status folder.
     */
    fun onPicked(c: Context, business: Boolean, tree: Uri): Boolean {
        c.contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(key(business), tree.toString()).apply()
        return DocumentsContract.getTreeDocumentId(tree).endsWith(".Statuses")
    }

    /** The folder Uri if access was granted (and not revoked since). */
    fun tree(c: Context, business: Boolean): Uri? {
        val saved = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(key(business), null) ?: return null
        val uri = Uri.parse(saved)
        val granted = c.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }
        return if (granted) uri else null
    }

    /** Statuses (photos and videos), newest first. */
    fun list(c: Context, business: Boolean): List<Map<String, Any?>>? {
        val tree = tree(c, business) ?: return null
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val cols = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_SIZE,
        )
        val out = ArrayList<Map<String, Any?>>()
        c.contentResolver.query(children, cols, null, null, null)?.use { cur ->
            while (cur.moveToNext()) {
                val name = cur.getString(1) ?: continue
                val mime = cur.getString(2) ?: continue
                if (name.startsWith(".") || !(mime.startsWith("image/") || mime.startsWith("video/"))) continue
                out += mapOf(
                    "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, cur.getString(0)).toString(),
                    "name" to name,
                    "mime" to mime,
                    "modified" to cur.getLong(3),
                    "size" to cur.getLong(4),
                )
            }
        }
        return out.sortedByDescending { it["modified"] as Long }
    }

    /** Small JPEG preview of a photo or video status. */
    fun thumbnail(c: Context, uriString: String, video: Boolean): ByteArray? {
        val uri = Uri.parse(uriString)
        val bmp: Bitmap? = try {
            if (video) {
                MediaMetadataRetriever().run {
                    try {
                        setDataSource(c, uri)
                        getScaledFrameAtTime(1_000_000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 360, 360)
                            ?: frameAtTime
                    } finally {
                        release()
                    }
                }
            } else {
                try {
                    c.contentResolver.loadThumbnail(uri, Size(360, 360), null)
                } catch (_: Exception) {
                    c.contentResolver.openInputStream(uri)?.use {
                        BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = 4 })
                    }
                }
            }
        } catch (_: Exception) {
            null
        }
        bmp ?: return null
        return ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
    }

    /** Copies a status into Pictures/AbhiUtility or Movies/AbhiUtility (shown in the Gallery). */
    fun save(c: Context, uriString: String, name: String, mime: String): String {
        val video = mime.startsWith("video/")
        val collection = if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val dir = if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "Status_$name")
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "$dir/AbhiUtility")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = c.contentResolver
        val target = resolver.insert(collection, values) ?: throw IllegalStateException("Could not create the file")
        try {
            resolver.openInputStream(Uri.parse(uriString))!!.use { input ->
                resolver.openOutputStream(target)!!.use { input.copyTo(it) }
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(target, values, null, null)
        } catch (e: Exception) {
            resolver.delete(target, null, null)
            throw e
        }
        return "$dir/AbhiUtility"
    }

    fun open(a: Activity, uriString: String, mime: String) {
        a.startActivity(
            Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(uriString), mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        )
    }
}
