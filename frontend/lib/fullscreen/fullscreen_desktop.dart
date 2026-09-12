import 'package:window_manager/window_manager.dart';

void toggleFullscreen(void Function(bool isFullscreen) onStateChanged) async {
  bool isFullScreen = await windowManager.isFullScreen();
  await windowManager.setFullScreen(!isFullScreen);
  onStateChanged(!isFullScreen);
}

void registerGlobalHotkey(void Function() onToggle) {
  // Desktop native hotkeys are best handled via Flutter's KeyboardListener or Shortcuts
  // To keep parity with web's global listener without breaking tree, we leave this empty here
  // and handle it via Flutter focus.
}

