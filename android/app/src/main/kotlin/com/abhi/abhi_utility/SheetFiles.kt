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
    private val EXTENSIONS = listOf("xlsx", "xlsm", "xls", "csv")

    private val MIME_TYPES = setOf(
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.ms-excel.sheet.macroenabled.12",
        "application/vnd.ms-excel",
        "text/csv",
        "text/comma-separated-values",
    )

    /** Is this (content type, file name) a spreadsheet the viewer handles? */
    fun isSheet(mime: String?, name: String?): Boolean =
        mime?.lowercase() in MIME_TYPES ||
            EXTENSIONS.any { name?.lowercase()?.endsWith(".$it") == true }

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

    /** Every spreadsheet MediaStore knows about, newest first. */
    fun scan(context: Context): List<Map<String, Any?>> {
        val collection = MediaStore.Files.getContentUri("external")
        @Suppress("DEPRECATION") // DATA (the path) is still filled in and lets Dart read the file directly
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.DATE_MODIFIED,
            MediaStore.Files.FileColumns.DATA,
        )
        val selection = EXTENSIONS.joinToString(" OR ") { "${MediaStore.Files.FileColumns.DISPLAY_NAME} LIKE ?" }
        val args = EXTENSIONS.map { "%.$it" }.toTypedArray()
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

    /** File name of a content:// uri (for the viewer title). */
    fun displayName(context: Context, uri: String): String? = try {
        context.contentResolver.query(Uri.parse(uri), arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    } catch (_: Exception) {
        null
    }

    /** Spreadsheet uri this app was opened with, or null. */
    fun incomingUri(context: Context, i: Intent?): String? {
        if (i?.action != Intent.ACTION_VIEW) return null
        val uri = i.data ?: return null
        val mime = i.type ?: try { context.contentResolver.getType(uri) } catch (_: Exception) { null }
        val name = displayName(context, uri.toString()) ?: uri.lastPathSegment
        return if (isSheet(mime, name)) uri.toString() else null
    }
}
