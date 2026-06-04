package com.clipmaster.editor

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Handles videos opened from outside the app ("Open with" / share).
 *
 * The incoming URI is usually a content:// URI that VideoPlayer / FFmpeg
 * cannot read directly, so it is copied to a real file in the app cache via
 * ContentResolver, which transparently supports every source (file managers,
 * gallery, WhatsApp, …). The copy runs off the main thread to avoid ANRs on
 * large files; Flutter shows a loading indicator while it runs.
 */
class MainActivity : FlutterActivity() {
    private val methodChannelName = "clip_master/incoming"
    private val eventChannelName = "clip_master/incoming_events"

    // URI from the launching intent (cold start), consumed once by Flutter.
    private var initialUri: String? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initialUri = extractUri(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialMedia" -> {
                        result.success(initialUri)
                        initialUri = null // consume once
                    }
                    "copyUriToTempFile" -> {
                        val uriStr = call.argument<String>("uri")
                        if (uriStr == null) {
                            result.error("NO_URI", "uri is null", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val map = copyToCache(Uri.parse(uriStr))
                                runOnUiThread { result.success(map) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("COPY_FAILED", e.message, null)
                                }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }

                override fun onCancel(args: Any?) {
                    eventSink = null
                }
            })
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val uri = extractUri(intent)
        if (uri != null) {
            val sink = eventSink
            if (sink != null) sink.success(uri) else initialUri = uri
        }
    }

    /** Pulls a video URI out of a VIEW or SEND intent. */
    private fun extractUri(intent: Intent?): String? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_VIEW -> intent.data?.toString()
            Intent.ACTION_SEND -> {
                val uri: Uri? = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                uri?.toString()
            }
            else -> null
        }
    }

    /** Copies [uri] into the cache dir and returns {path, name}. */
    private fun copyToCache(uri: Uri): HashMap<String, String> {
        val displayName = queryDisplayName(uri)
            ?: ("video_" + System.currentTimeMillis() + guessExt(uri))
        val safeName = displayName.replace(Regex("[/\\\\]"), "_")
        val outFile = File(cacheDir, "incoming_" + System.currentTimeMillis() + "_" + safeName)

        contentResolver.openInputStream(uri).use { input ->
            if (input == null) throw IllegalStateException("Cannot open input stream for $uri")
            outFile.outputStream().use { output ->
                input.copyTo(output, 1024 * 1024)
            }
        }
        if (outFile.length() <= 0L) throw IllegalStateException("Copied file is empty")

        return hashMapOf(
            "path" to outFile.absolutePath,
            "name" to displayName,
        )
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        var name: String? = null
        try {
            contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
            )?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) name = c.getString(idx)
                }
            }
        } catch (_: Exception) {
        }
        return name
    }

    private fun guessExt(uri: Uri): String {
        val type = contentResolver.getType(uri)
        return when {
            type == null -> ".mp4"
            type.contains("quicktime") -> ".mov"
            type.contains("3gpp") -> ".3gp"
            type.contains("matroska") -> ".mkv"
            type.contains("webm") -> ".webm"
            type.contains("x-msvideo") -> ".avi"
            else -> ".mp4"
        }
    }
}
