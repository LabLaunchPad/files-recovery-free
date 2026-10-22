package com.filesrecovery.free.files_recovery_free

import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * MainActivity — hosts the Flutter app and exposes the Android-only SAF
 * ingestion bridge (Phase 4 disk-image import):
 *
 *   MethodChannel "frf/saf"
 *     ingestToCache(uri: String) -> String (absolute cache path)
 *
 * The system document picker returns `content://` URIs that dart:io cannot
 * open by path, so this streams the document into cacheDir/frf_import/
 * (one file at a time, streamed in 1 MiB chunks) and hands back the copy's
 * absolute path for the engine to scan read-only. The original document is
 * never modified.
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "frf/saf")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ingestToCache" -> {
                        val uri = call.argument<String>("uri")
                        if (uri.isNullOrBlank()) {
                            result.error("invalid_arg", "uri is missing", null)
                        } else {
                            try {
                                result.success(ingestToCache(Uri.parse(uri)))
                            } catch (e: SecurityException) {
                                result.error("permission_denied", e.message, null)
                            } catch (e: Exception) {
                                result.error("ingest_failed", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Streams the SAF document into the app cache; returns the copy's path. */
    private fun ingestToCache(uri: Uri): String {
        val resolver = applicationContext.contentResolver
        val safeName = queryDisplayName(uri, resolver)
            ?.replace(Regex("[^A-Za-z0-9._-]"), "_")
            ?.ifBlank { null }
            ?: "imported.img"
        val dir = File(applicationContext.cacheDir, "frf_import").apply { mkdirs() }
        val out = File(dir, "${System.currentTimeMillis()}_$safeName")
        val input = resolver.openInputStream(uri)
            ?: throw IllegalStateException("cannot open $uri")
        input.use { stream ->
            out.outputStream().use { output -> stream.copyTo(output, 1 shl 20) }
        }
        return out.absolutePath
    }

    private fun queryDisplayName(uri: Uri, resolver: android.content.ContentResolver): String? =
        try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                }
        } catch (e: Exception) {
            null
        }
}
