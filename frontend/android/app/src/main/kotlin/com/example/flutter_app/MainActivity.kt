package com.example.flutter_app

import android.os.Bundle
import android.util.Log
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : FlutterActivity() {
    private val TAG = "MainActivity"
    private val CHANNEL = "wtt/ytdlp"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!Python.isStarted()) {
            Log.i(TAG, "Starting Chaquopy Python platform...")
            Python.start(AndroidPlatform(this))
            Log.i(TAG, "Chaquopy Python platform started successfully.")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getVideoStreamMetadata" -> {
                    val youtubeId = call.argument<String>("youtubeId")
                    if (youtubeId.isNullOrEmpty()) {
                        result.error("INVALID_ARGUMENT", "youtubeId is required", null)
                        return@setMethodCallHandler
                    }

                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val py = Python.getInstance()
                            val pyModule = py.getModule("ytdlp_runner")
                            val jsonString = pyModule.callAttr("extract_stream_metadata", youtubeId).toString()
                            withContext(Dispatchers.Main) {
                                result.success(jsonString)
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "Extraction failed for $youtubeId", e)
                            withContext(Dispatchers.Main) {
                                result.error("EXTRACTION_FAILED", e.localizedMessage, null)
                            }
                        }
                    }
                }
                "updateYtDlp" -> {
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val py = Python.getInstance()
                            val pyModule = py.getModule("ytdlp_runner")
                            val status = pyModule.callAttr("update_ytdlp").toString()
                            withContext(Dispatchers.Main) {
                                result.success(status)
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "Update failed", e)
                            withContext(Dispatchers.Main) {
                                result.error("UPDATE_FAILED", e.localizedMessage, null)
                            }
                        }
                    }
                }
                "getYtDlpVersion" -> {
                    try {
                        val py = Python.getInstance()
                        val pyModule = py.getModule("ytdlp_runner")
                        val version = pyModule.callAttr("get_ytdlp_version").toString()
                        result.success(version)
                    } catch (e: Exception) {
                        result.error("VERSION_CHECK_FAILED", e.localizedMessage, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
