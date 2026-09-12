void toggleFullscreen(void Function(bool isFullscreen) onStateChanged) {
  // On the web, we strictly rely on the native YouTube iframe fullscreen button.
  // Programmatic HTML5 fullscreen is blocked by cross-origin security policies
  // unless triggered by a direct, synchronous user interaction inside the iframe.
}

void registerGlobalHotkey(void Function() onToggle) {
  // No custom hotkeys for web fullscreen. The user must use the YouTube player UI.
}

