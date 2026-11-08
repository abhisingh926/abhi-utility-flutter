package com.abhi.abhi_utility

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import java.io.File

/**
 * Excel viewer: finds every spreadsheet on the phone (needs "All files access"
 * on Android 11+, because other apps' documents are hidden from MediaStore
 * otherwise) and reads files picked by the user or opened with
 * "Open with → Abhi Utility".
 */
object SheetFiles {
    /** Spreadsheets (Excel viewer) or documents (Docs). */
    enum class Kind(
        /** Listed by [scan] and recognised by name. */
        val extensions: List<String>,
        val mimeTypes: Set<String>,
        /** Recognised when opened with the app, but not listed (there are too many). */
        val openOnly: List<String> = emptyList(),
    ) {
        SHEETS(
            listOf("xlsx", "xlsm", "xls", "csv"),
            setOf(
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                "application/vnd.ms-excel.sheet.macroenabled.12",
                "application/vnd.ms-excel",
                "text/csv",
                "text/comma-separated-values",
            ),
        ),
        DOCS(
            listOf("docx", "doc"),
            setOf(
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                "application/msword",
            ),
            openOnly = listOf("txt"),
        );

        /** Is this (content type, file name) a file of this kind? */
        fun matches(mime: String?, name: String?): Boolean =
            mime?.lowercase() in mimeTypes ||
                (extensions + openOnly).any { name?.lowercase()?.endsWith(".$it") == true }
    }

    /** May we list every spreadsheet on the phone? */
    fun hasAllFilesAccess(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else context.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    /** Android 11+: the "All files access" settings page for this app; older: the storage permission. */
    fun requestAllFilesAccess(activity: Activity) {
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                activity.startActivity(
                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                        .setData(Uri.parse("package:${activity.packageName}"))
                )
            } catch (_: Exception) {
                activity.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            activity.requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE), 101)
        }
    }

    /** Every file of [kind] MediaStore knows about, newest first. */
    fun scan(context: Context, kind: Kind): List<Map<String, Any?>> {
        val extensions = kind.extensions
        val collection = MediaStore.Files.getContentUri("external")
        @Suppress("DEPRECATION") // DATA (the path) is still filled in and lets Dart read the file directly
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.DATE_MODIFIED,
            MediaStore.Files.FileColumns.DATA,
        )
        val selection = extensions.joinToString(" OR ") { "${MediaStore.Files.FileColumns.DISPLAY_NAME} LIKE ?" }
        val args = extensions.map { "%.$it" }.toTypedArray()
        val out = mutableListOf<Map<String, Any?>>()
        context.contentResolver.query(
            collection, projection, selection, args,
            "${MediaStore.Files.FileColumns.DATE_MODIFIED} DESC"
        )?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(1) ?: continue
                val path = c.getString(4)
                if (path != null && path.contains("/.")) continue // hidden folders (app caches, trash)
                out += mapOf(
                    "name" to name,
                    "path" to path,
                    "uri" to ContentUris.withAppendedId(collection, c.getLong(0)).toString(),
                    "size" to c.getLong(2),
                    "modified" to c.getLong(3) * 1000,
                )
            }
        }
        return out
    }

    /** Bytes of a content:// / file:// uri or a plain path. */
    fun read(context: Context, source: String): ByteArray =
        if (source.startsWith("content://") || source.startsWith("file://")) {
            context.contentResolver.openInputStream(Uri.parse(source))!!.use { it.readBytes() }
        } else {
            File(source).readBytes()
        }

    /**
     * Saves over the original: a content:// uri the app may write to, or a path
     * (needs "All files access" outside the app's own folders). Throws if not allowed.
     */
    fun write(context: Context, source: String, bytes: ByteArray) {
        if (source.startsWith("content://")) {
            val out = context.contentResolver.openOutputStream(Uri.parse(source), "wt")
                ?: throw SecurityException("Not allowed to change this file")
            out.use { it.write(bytes) }
            return
        }
        val file = File(source.removePrefix("file://"))
        // The app's own cache (e.g. a picked copy) is not the user's file.
        if (file.absolutePath.startsWith(context.cacheDir.parentFile!!.absolutePath)) {
            throw SecurityException("This is a temporary copy")
        }
        // Write next to it, then replace: a failed save never leaves half a file.
        val tmp = File(file.parentFile, ".${file.name}.saving")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(file)) {
            tmp.delete()
            file.writeBytes(bytes)
        }
    }

    /** Saves a copy in Downloads/AbhiUtility (no permission needed); returns its content:// uri. */
    fun saveCopy(context: Context, bytes: ByteArray, name: String, mime: String): String {
        val resolver = context.contentResolver
        val values = android.content.ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/AbhiUtility")
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

    /** File name of a content:// uri (for the viewer title). */
    fun displayName(context: Context, uri: String): String? = try {
        context.contentResolver.query(Uri.parse(uri), arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    } catch (_: Exception) {
        null
    }

    /** File of [kind] this app was opened with ("Open with"), or null. */
    fun incomingUri(context: Context, i: Intent?, kind: Kind): String? {
        if (i?.action != Intent.ACTION_VIEW) return null
        val uri = i.data ?: return null
        val mime = i.type ?: try { context.contentResolver.getType(uri) } catch (_: Exception) { null }
        val name = displayName(context, uri.toString()) ?: uri.lastPathSegment
        return if (kind.matches(mime, name)) uri.toString() else null
    }
}
