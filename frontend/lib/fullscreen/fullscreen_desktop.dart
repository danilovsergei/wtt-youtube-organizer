import 'dart:io';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

bool _isMobileFullscreen = false;

void toggleFullscreen(void Function(bool isFullscreen) onStateChanged) async {
  if (Platform.isAndroid || Platform.isIOS) {
    _isMobileFullscreen = !_isMobileFullscreen;
    if (_isMobileFullscreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    onStateChanged(_isMobileFullscreen);
    return;
  }
  bool isFullScreen = await windowManager.isFullScreen();
  await windowManager.setFullScreen(!isFullScreen);
  onStateChanged(!isFullScreen);
}

void registerGlobalHotkey(void Function() onToggle) {
  // Desktop native hotkeys are best handled via Flutter's KeyboardListener or Shortcuts
}
