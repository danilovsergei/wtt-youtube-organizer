package com.example.native_surface_view

import io.flutter.embedding.engine.plugins.FlutterPlugin

class NativeSurfaceViewPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        binding.platformViewRegistry.registerViewFactory(
            "wtt_native_surface_view",
            NativeSurfaceViewFactory(binding.binaryMessenger)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
