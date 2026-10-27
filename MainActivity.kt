package com.przesyl.przesyl

import android.content.ContentValues
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// Zapisuje odebrane pliki do publicznego folderu Pobrane/Przesyl,
// tak żeby były widoczne w aplikacji Pliki i w Galerii.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "przesyl/media")
            .setMethodCallHandler { call, result ->
                if (call.method == "saveToDownloads") {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name")
                    if (path == null || name == null) {
                        result.error("ARGS", "Brak argumentów", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val saved = save(File(path), name)
                            runOnUiThread { result.success(saved) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SAVE", e.message, null) }
                        }
                    }.start()
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun mimeOf(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
    }

    private fun save(src: File, name: String): String {
        val mime = mimeOf(name)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Przesyl")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw Exception("Nie można utworzyć pliku")
            try {
                resolver.openOutputStream(uri)!!.use { out ->
                    src.inputStream().use { it.copyTo(out, 1 shl 16) }
                }
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            } finally {
                src.delete()
            }
            return "Pobrane/Przesyl/$name"
        }

        // Android 9 i starsze
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "Przesyl"
        )
        dir.mkdirs()
        val base = name.substringBeforeLast('.')
        val ext = if (name.contains('.')) "." + name.substringAfterLast('.') else ""
        var dest = File(dir, name)
        var i = 1
        while (dest.exists()) {
            dest = File(dir, "$base ($i)$ext")
            i++
        }
        try {
            src.copyTo(dest)
        } finally {
            src.delete()
        }
        MediaScannerConnection.scanFile(this, arrayOf(dest.absolutePath), arrayOf(mime), null)
        return dest.absolutePath
    }
}
