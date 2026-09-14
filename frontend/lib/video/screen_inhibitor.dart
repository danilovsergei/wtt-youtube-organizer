import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dbus/dbus.dart';

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

