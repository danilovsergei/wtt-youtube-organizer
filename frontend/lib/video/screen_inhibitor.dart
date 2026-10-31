import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dbus/dbus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

abstract class ScreenLockInhibitor {
  Future<void> enable();
  Future<void> disable();
}

class DefaultScreenLockInhibitor implements ScreenLockInhibitor {
  Timer? _heartbeatTimer;
  final Duration heartbeatInterval;
  int heartbeatCount = 0;

  DefaultScreenLockInhibitor({
    this.heartbeatInterval = const Duration(seconds: 30),
  });

  bool get isHeartbeatActive => _heartbeatTimer != null && _heartbeatTimer!.isActive;

  @override
  Future<void> enable() async {
    await _performInhibit();
    _startHeartbeat();
  }

  @override
  Future<void> disable() async {
    _stopHeartbeat();
    await _performUninhibit();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      heartbeat();
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> heartbeat() async {
    heartbeatCount++;
    try {
      await WakelockPlus.enable();
    } catch (_) {}
    if (!kIsWeb && Platform.isLinux) {
      await LinuxScreenInhibitor.simulateUserActivity();
    }
  }

  Future<void> _performInhibit() async {
    try {
      await WakelockPlus.enable();
    } catch (e) {
      debugPrint("WakelockPlus.enable() error: $e");
    }
    if (!kIsWeb && Platform.isLinux) {
      await LinuxScreenInhibitor.enable();
    }
  }

  Future<void> _performUninhibit() async {
    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint("WakelockPlus.disable() error: $e");
    }
    if (!kIsWeb && Platform.isLinux) {
      await LinuxScreenInhibitor.disable();
    }
  }
}

class ScreenLockService {
  static ScreenLockInhibitor instance = DefaultScreenLockInhibitor();

  static Future<void> enable() => instance.enable();
  static Future<void> disable() => instance.disable();
}

class LinuxScreenInhibitor {
  static DBusClient? _client;
  static int? _fdCookie;
  static int? _gnomeCookie;

  static Future<void> enable() async {
    debugPrint("DIAGNOSTICS: Native LinuxScreenInhibitor.enable() via DBus package called");
    if (_client == null) {
      _client = DBusClient.session();
    }
    
    // Try org.freedesktop.ScreenSaver
    try {
      final object = DBusRemoteObject(
        _client!,
        name: 'org.freedesktop.ScreenSaver',
        path: DBusObjectPath('/org/freedesktop/ScreenSaver'),
      );
      final response = await object.callMethod(
        'org.freedesktop.ScreenSaver',
        'Inhibit',
        [DBusString('WTT Video'), DBusString('Playing Match')],
        replySignature: DBusSignature('u')
      );
      _fdCookie = response.returnValues[0].asUint32();
      debugPrint("DIAGNOSTICS: fd.ScreenSaver Inhibit Success! Cookie: $_fdCookie");
    } catch (e) {
      debugPrint("DIAGNOSTICS: fd.ScreenSaver Error: $e");
    }

    // Try org.gnome.SessionManager
    try {
      final object = DBusRemoteObject(
        _client!,
        name: 'org.gnome.SessionManager',
        path: DBusObjectPath('/org/gnome/SessionManager'),
      );
      final response = await object.callMethod(
        'org.gnome.SessionManager',
        'Inhibit',
        [DBusString('WTT Video'), DBusUint32(0), DBusString('Playing Match'), DBusUint32(8)],
        replySignature: DBusSignature('u')
      );
      _gnomeCookie = response.returnValues[0].asUint32();
      debugPrint("DIAGNOSTICS: gnome.SessionManager Inhibit Success! Cookie: $_gnomeCookie");
    } catch (e) {
      debugPrint("DIAGNOSTICS: gnome.SessionManager Error: $e");
    }
  }

  static Future<void> simulateUserActivity() async {
    if (_client == null) {
      _client = DBusClient.session();
    }
    try {
      final object = DBusRemoteObject(
        _client!,
        name: 'org.freedesktop.ScreenSaver',
        path: DBusObjectPath('/org/freedesktop/ScreenSaver'),
      );
      await object.callMethod(
        'org.freedesktop.ScreenSaver',
        'SimulateUserActivity',
        [],
        replySignature: DBusSignature('')
      );
      debugPrint("DIAGNOSTICS: fd.ScreenSaver SimulateUserActivity heartbeat sent");
    } catch (e) {
      debugPrint("DIAGNOSTICS: fd.ScreenSaver SimulateUserActivity error: $e");
    }
  }

  static Future<void> disable() async {
    debugPrint("DIAGNOSTICS: Native LinuxScreenInhibitor.disable() called");
    if (_client == null) return;
    
    if (_fdCookie != null) {
      try {
        final object = DBusRemoteObject(
          _client!,
          name: 'org.freedesktop.ScreenSaver',
          path: DBusObjectPath('/org/freedesktop/ScreenSaver'),
        );
        await object.callMethod(
          'org.freedesktop.ScreenSaver',
          'UnInhibit',
          [DBusUint32(_fdCookie!)],
          replySignature: DBusSignature('')
        );
        _fdCookie = null;
      } catch (e) {
        debugPrint("DIAGNOSTICS: fd.ScreenSaver UnInhibit Error: $e");
      }
    }

    if (_gnomeCookie != null) {
      try {
        final object = DBusRemoteObject(
          _client!,
          name: 'org.gnome.SessionManager',
          path: DBusObjectPath('/org/gnome/SessionManager'),
        );
        await object.callMethod(
          'org.gnome.SessionManager',
          'Uninhibit',
          [DBusUint32(_gnomeCookie!)],
          replySignature: DBusSignature('')
        );
        _gnomeCookie = null;
      } catch (e) {
        debugPrint("DIAGNOSTICS: gnome.SessionManager UnInhibit Error: $e");
      }
    }
  }
}
