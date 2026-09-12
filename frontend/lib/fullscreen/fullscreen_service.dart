import 'fullscreen_desktop.dart' if (dart.library.html) 'fullscreen_web.dart' as impl;

abstract class FullscreenService {
  static void toggleFullscreen(void Function(bool isFullscreen) onStateChanged) {
    impl.toggleFullscreen(onStateChanged);
  }

  static void registerGlobalHotkey(void Function() onToggle) {
    impl.registerGlobalHotkey(onToggle);
  }
}

