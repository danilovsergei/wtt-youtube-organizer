package com.example.native_surface_view

import android.content.Context
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec

class NativeSurfacePlatformView(
    context: Context,
    id: Int,
    creationParams: Map<String?, Any?>?,
    messenger: BinaryMessenger
) : PlatformView, SurfaceHolder.Callback {
    private val TAG = "NativeSurfaceView"
    private val surfaceView = SurfaceView(context).apply {
        isFocusable = false
        isFocusableInTouchMode = false
        setZOrderMediaOverlay(true)
        holder.addCallback(this@NativeSurfacePlatformView)
    }
    private val channel = MethodChannel(messenger, "wtt_native_surface_" + id)
    private var widRef: Long = 0

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getWid" -> {
                    Log.i(TAG, "getWid queried from Dart! Returning: " + widRef)
                    result.success(widRef)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun getView(): View = surfaceView

    override fun surfaceCreated(holder: SurfaceHolder) {
        try {
            val helperClass = Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper")
            val newRefMethod = helperClass.getDeclaredMethod("newGlobalObjectRef", Any::class.java)
            newRefMethod.isAccessible = true
            widRef = newRefMethod.invoke(null, holder.surface) as Long
            Log.i(TAG, "Native Surface created! widRef=" + widRef)
            channel.invokeMethod("onSurfaceCreated", mapOf("wid" to widRef))
        } catch (e: Exception) {
            Log.e(TAG, "Failed to obtain native Surface wid", e)
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        Log.i(TAG, "Surface changed: " + width + "x" + height)
        channel.invokeMethod("onSurfaceChanged", mapOf("width" to width, "height" to height))
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        Log.i(TAG, "Surface destroyed! widRef=" + widRef)
        channel.invokeMethod("onSurfaceDestroyed", null)
        cleanupRef()
    }

    private fun cleanupRef() {
        if (widRef != 0L) {
            try {
                val helperClass = Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper")
                val delRefMethod = helperClass.getDeclaredMethod("deleteGlobalObjectRef", Long::class.javaPrimitiveType)
                delRefMethod.isAccessible = true
                delRefMethod.invoke(null, widRef)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to release native Surface wid", e)
            }
            widRef = 0L
        }
    }

    override fun dispose() {
        cleanupRef()
        surfaceView.holder.removeCallback(this)
    }
}

class NativeSurfaceViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val creationParams = args as? Map<String?, Any?>
        return NativeSurfacePlatformView(context, viewId, creationParams, messenger)
    }
}
