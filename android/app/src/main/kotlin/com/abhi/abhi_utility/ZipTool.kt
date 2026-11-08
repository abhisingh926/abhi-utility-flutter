package com.abhi.abhi_utility

import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import net.lingala.zip4j.ZipFile
import net.lingala.zip4j.exception.ZipException
import net.lingala.zip4j.model.FileHeader
import net.lingala.zip4j.model.ZipParameters
import net.lingala.zip4j.model.enums.AesKeyStrength
import net.lingala.zip4j.model.enums.EncryptionMethod
import java.io.File
import java.io.InputStream

/**
 * Zip / unzip / view / lock zip files (zip4j; locks use AES-256).
 * New zips go to Downloads/AbhiUtility/Zips, unzipped files to Downloads/AbhiUtility/Unzipped/<zip name>/.
 */
object ZipTool {
    private const val ZIPS = "AbhiUtility/Zips"
    private const val UNZIPPED = "AbhiUtility/Unzipped"

    class WrongPassword : Exception("Wrong password")

    private fun safeName(name: String) = name.replace(Regex("""[\\/:*?"<>|]"""), "_").trim().ifEmpty { "file" }

    private fun params(fileName: String, password: String?) = ZipParameters().apply {
        fileNameInZip = fileName
        if (!password.isNullOrEmpty()) {
            isEncryptFiles = true
            encryptionMethod = EncryptionMethod.AES
            aesKeyStrength = AesKeyStrength.KEY_STRENGTH_256
        }
    }

    private fun open(path: String, password: String?): ZipFile =
        if (password.isNullOrEmpty()) ZipFile(path) else ZipFile(path, password.toCharArray())

    private fun displayName(context: Context, uri: Uri): String? = try {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst() && !c.isNull(0)) c.getString(0) else null }
    } catch (_: Exception) {
        null
    }

    private fun openInput(context: Context, src: String): InputStream =
        if (src.startsWith("content:")) context.contentResolver.openInputStream(Uri.parse(src))!!
        else File(src.removePrefix("file://")).inputStream()

    /** Copies a picked zip (content:// or file path) to the cache so zip4j can read it. */
    fun localCopy(context: Context, src: String): String {
        if (!src.startsWith("content:")) return src.removePrefix("file://")
        var name = displayName(context, Uri.parse(src)) ?: "archive.zip"
        name = safeName(name)
        val dir = File(context.cacheDir, "zip_open/${System.currentTimeMillis()}").apply { mkdirs() }
        val out = File(dir, name)
        openInput(context, src).use { input -> out.outputStream().use { input.copyTo(it) } }
        return out.absolutePath
    }

    // ---- Saving into Downloads ------------------------------------------------------------

    private fun mime(name: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
            ?: "application/octet-stream"

    /** Writes [write] to Downloads/<folder>/<name>, replacing an older copy we made. */
    private fun saveToDownloads(context: Context, folder: String, name: String, write: (java.io.OutputStream) -> Unit): Uri {
        val resolver = context.contentResolver
        val path = "${Environment.DIRECTORY_DOWNLOADS}/$folder/"
        resolver.delete(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            "${MediaStore.Downloads.DISPLAY_NAME}=? AND ${MediaStore.Downloads.RELATIVE_PATH}=?",
            arrayOf(name, path),
        )
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime(name))
            put(MediaStore.Downloads.RELATIVE_PATH, path)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Could not create $name in Downloads")
        try {
            resolver.openOutputStream(uri)!!.use(write)
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return uri
    }

    private fun result(uri: Uri, name: String, path: String) =
        mapOf("uri" to uri.toString(), "name" to name, "path" to path, "size" to File(path).length())

    private fun zipName(name: String) = safeName(name).let { if (it.lowercase().endsWith(".zip")) it else "$it.zip" }

    /** Builds a zip in the cache, then copies it to Downloads/AbhiUtility/Zips. */
    private fun build(context: Context, name: String, fill: (ZipFile) -> Unit): Map<String, Any> {
        val dir = File(context.cacheDir, "zip_out/${System.currentTimeMillis()}").apply { mkdirs() }
        val tmp = File(dir, zipName(name))
        val zip = ZipFile(tmp)
        zip.use(fill)
        val uri = saveToDownloads(context, ZIPS, tmp.name) { out -> tmp.inputStream().use { it.copyTo(out) } }
        return result(uri, tmp.name, tmp.absolutePath)
    }

    // ---- Create -----------------------------------------------------------------------

    /** files: [{src: content uri or path, name}] */
    fun create(context: Context, files: List<Map<String, String>>, name: String, password: String?): Map<String, Any> =
        build(context, name) { zip ->
            if (!password.isNullOrEmpty()) zip.setPassword(password.toCharArray())
            val used = mutableSetOf<String>()
            for (f in files) {
                val src = f["src"] ?: continue
                var entry = safeName(f["name"] ?: displayName(context, Uri.parse(src)) ?: "file")
                // Two picked files with the same name: "photo.jpg", "photo (2).jpg"
                if (!used.add(entry.lowercase())) {
                    val base = entry.substringBeforeLast('.'); val ext = entry.substringAfterLast('.', "")
                    var n = 2
                    while (!used.add("$base ($n)${if (ext.isEmpty()) "" else ".$ext"}".lowercase())) n++
                    entry = "$base ($n)${if (ext.isEmpty()) "" else ".$ext"}"
                }
                openInput(context, src).use { zip.addStream(it, params(entry, password)) }
            }
        }

    // ---- View -------------------------------------------------------------------------

    fun list(path: String): Map<String, Any> {
        val zip = ZipFile(path)
        zip.use {
            if (!it.isValidZipFile) throw IllegalArgumentException("This is not a zip file (or it is damaged)")
            val headers = it.fileHeaders
            return mapOf(
                "encrypted" to it.isEncrypted,
                "entries" to headers.map { h ->
                    mapOf(
                        "name" to h.fileName,
                        "dir" to h.isDirectory,
                        "size" to h.uncompressedSize,
                        "compressed" to h.compressedSize,
                        "encrypted" to h.isEncrypted,
                        "time" to h.lastModifiedTimeEpoch,
                    )
                },
            )
        }
    }

    private fun firstEncrypted(zip: ZipFile): FileHeader? =
        zip.fileHeaders.firstOrNull { !it.isDirectory && it.isEncrypted }

    /** Reads an entry fully (to /dev/null); a wrong password fails here. */
    private fun verify(zip: ZipFile, h: FileHeader) {
        try {
            zip.getInputStream(h).use { input ->
                val buf = ByteArray(64 * 1024)
                while (input.read(buf) >= 0) Unit
            }
        } catch (e: ZipException) {
            if (e.type == ZipException.Type.WRONG_PASSWORD || e.message?.contains("password", true) == true) throw WrongPassword()
            throw e
        }
    }

    fun checkPassword(path: String, password: String): Boolean = open(path, password).use { zip ->
        val h = firstEncrypted(zip) ?: return true
        try {
            verify(zip, h); true
        } catch (_: WrongPassword) {
            false
        } catch (e: java.io.IOException) {
            if (e.message?.contains("password", true) == true) false else throw e
        }
    }

    private fun safeEntryPath(name: String): List<String> =
        name.replace('\\', '/').split('/').filter { it.isNotEmpty() && it != "." && it != ".." }.map(::safeName)

    /** Extracts one entry to the cache and returns its path (for preview). */
    fun preview(context: Context, path: String, password: String?, entry: String): String = open(path, password).use { zip ->
        val h = zip.getFileHeader(entry) ?: throw IllegalArgumentException("Not found in the zip: $entry")
        val dir = File(context.cacheDir, "zip_preview/${System.currentTimeMillis()}").apply { mkdirs() }
        val out = File(dir, safeEntryPath(entry).lastOrNull() ?: "file")
        zip.getInputStream(h).use { input -> out.outputStream().use { input.copyTo(it) } }
        out.absolutePath
    }

    /**
     * Extracts [entries] (all when null) to Downloads/AbhiUtility/Unzipped/<folder>/, keeping
     * the folders inside the zip. Returns the number of files and where they went.
     */
    fun extract(context: Context, path: String, password: String?, entries: List<String>?, folder: String): Map<String, Any> =
        open(path, password).use { zip ->
            val want = entries?.toSet()
            val root = "$UNZIPPED/${safeName(folder)}"
            var count = 0
            var last: Uri? = null
            for (h in zip.fileHeaders) {
                if (h.isDirectory) continue
                if (want != null && h.fileName !in want) continue
                val parts = safeEntryPath(h.fileName)
                if (parts.isEmpty()) continue
                val sub = (listOf(root) + parts.dropLast(1)).joinToString("/")
                try {
                    last = saveToDownloads(context, sub, parts.last()) { out ->
                        zip.getInputStream(h).use { it.copyTo(out) }
                    }
                } catch (e: ZipException) {
                    if (e.type == ZipException.Type.WRONG_PASSWORD) throw WrongPassword()
                    throw e
                }
                count++
            }
            mapOf("count" to count, "folder" to "Download/$root", "uri" to (last?.toString() ?: ""))
        }

    // ---- Lock / unlock --------------------------------------------------------------------

    /** Makes a copy of the zip locked with [newPassword] (or unlocked when null/empty). */
    fun relock(context: Context, path: String, oldPassword: String?, newPassword: String?, name: String): Map<String, Any> =
        open(path, oldPassword).use { src ->
            build(context, name) { dst ->
                if (!newPassword.isNullOrEmpty()) dst.setPassword(newPassword.toCharArray())
                for (h in src.fileHeaders) {
                    if (h.isDirectory) continue
                    try {
                        src.getInputStream(h).use { dst.addStream(it, params(h.fileName, newPassword)) }
                    } catch (e: ZipException) {
                        if (e.type == ZipException.Type.WRONG_PASSWORD) throw WrongPassword()
                        throw e
                    }
                }
            }
        }

    // ---- Zips made by the app -----------------------------------------------------------

    fun recent(context: Context): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        val path = "${Environment.DIRECTORY_DOWNLOADS}/$ZIPS/"
        context.contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            arrayOf(MediaStore.Downloads._ID, MediaStore.Downloads.DISPLAY_NAME, MediaStore.Downloads.SIZE, MediaStore.Downloads.DATE_MODIFIED),
            "${MediaStore.Downloads.RELATIVE_PATH}=?", arrayOf(path),
            "${MediaStore.Downloads.DATE_MODIFIED} DESC",
        )?.use { c ->
            while (c.moveToNext()) {
                val uri = ContentUris.withAppendedId(MediaStore.Downloads.EXTERNAL_CONTENT_URI, c.getLong(0))
                out += mapOf("uri" to uri.toString(), "name" to c.getString(1), "size" to c.getLong(2), "time" to c.getLong(3) * 1000)
            }
        }
        return out
    }

    fun delete(context: Context, uri: String) {
        context.contentResolver.delete(Uri.parse(uri), null, null)
    }

    fun share(activity: Activity, uri: String, name: String) {
        val intent = Intent(Intent.ACTION_SEND)
            .setType(if (name.lowercase().endsWith(".zip")) "application/zip" else mime(name))
            .putExtra(Intent.EXTRA_STREAM, Uri.parse(uri))
            .putExtra(Intent.EXTRA_SUBJECT, name)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        activity.startActivity(Intent.createChooser(intent, "Share $name"))
    }

    /** Opens a saved file (content:// from Downloads) with another app. */
    fun openWith(activity: Activity, uri: String, name: String) {
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(Uri.parse(uri), mime(name))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        activity.startActivity(Intent.createChooser(intent, "Open $name"))
    }
}
