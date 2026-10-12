import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

typedef OnSurfaceCreatedCallback = void Function(int wid);
typedef OnSurfaceChangedCallback = void Function(int width, int height);

class _ConfigShim {
  const _ConfigShim();
  String get vo => "gpu";
}

class NativeSurfaceView extends StatefulWidget {
  final Player? player;
  final dynamic controls;
  final OnSurfaceCreatedCallback onSurfaceCreated;
  final OnSurfaceChangedCallback? onSurfaceChanged;
  final VoidCallback? onSurfaceDestroyed;

  const NativeSurfaceView({
    super.key,
    this.player,
    dynamic controller,
    this.controls,
    required this.onSurfaceCreated,
    this.onSurfaceChanged,
    this.onSurfaceDestroyed,
  });

  dynamic get controller => this;
  dynamic get configuration => const _ConfigShim();

  @override
  State<NativeSurfaceView> createState() => _NativeSurfaceViewState();
}

class _NativeSurfaceViewState extends State<NativeSurfaceView> {
  MethodChannel? _channel;

  void _onPlatformViewCreated(int id) async {
    _channel = MethodChannel('wtt_native_surface_$id');
    _channel?.setMethodCallHandler((call) async {
      if (call.method == 'onSurfaceCreated') {
        final dynamic raw = (call.arguments as Map)['wid'];
        if (raw is num && raw != 0) widget.onSurfaceCreated(raw.toInt());
      } else if (call.method == 'onSurfaceChanged') {
        final w = (call.arguments as Map)['width'] as int;
        final h = (call.arguments as Map)['height'] as int;
        widget.onSurfaceChanged?.call(w, h);
      } else if (call.method == 'onSurfaceDestroyed') {
        widget.onSurfaceDestroyed?.call();
      }
    });

    try {
      final dynamic raw = await _channel?.invokeMethod('getWid');
      if (raw is num && raw != 0) {
        widget.onSurfaceCreated(raw.toInt());
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return const SizedBox.shrink();
    }

    const viewType = 'wtt_native_surface_view';

    return PlatformViewLink(
      viewType: viewType,
      surfaceFactory: (BuildContext context, PlatformViewController controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        );
      },
      onCreatePlatformView: (PlatformViewCreationParams params) {
        return PlatformViewsService.initSurfaceAndroidView(
          id: params.id,
          viewType: viewType,
          layoutDirection: TextDirection.ltr,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener((id) {
            params.onPlatformViewCreated(id);
            _onPlatformViewCreated(id);
          })
          ..create();
      },
    );
  }
}
