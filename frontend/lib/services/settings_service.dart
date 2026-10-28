import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SettingsService {
  static final SettingsService instance = SettingsService._();
  SettingsService._();

  static const MethodChannel _channel = MethodChannel('wtt/settings');

  @visibleForTesting
  String? customSettingsPath;

  Future<File?> _getSettingsFile() async {
    if (kIsWeb) return null;

    if (customSettingsPath != null) {
      return File(customSettingsPath!);
    }

    if (Platform.isLinux) {
      final configHome = Platform.environment['XDG_CONFIG_HOME'];
      final home = Platform.environment['HOME'] ?? '.';
      final baseDir = configHome != null && configHome.isNotEmpty
          ? configHome
          : '$home/.config';
      final dir = Directory('$baseDir/wtt_organizer');
      if (!await dir.exists()) {
        try {
          await dir.create(recursive: true);
        } catch (_) {}
      }
      return File('${dir.path}/settings.json');
    }

    if (Platform.isAndroid) {
      String? dirPath;
      try {
        dirPath = await _channel.invokeMethod<String>('getFilesDir');
      } catch (_) {}

      dirPath ??= '/data/user/0/com.example.flutter_app/files';
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        try {
          await dir.create(recursive: true);
        } catch (_) {
          final fallback = Directory('/data/data/com.example.flutter_app/files');
          try {
            await fallback.create(recursive: true);
            return File('${fallback.path}/settings.json');
          } catch (_) {
            return null;
          }
        }
      }
      return File('${dir.path}/settings.json');
    }

    return null;
  }

  Future<Set<String>> loadSelectedTournamentTypeNames() async {
    if (kIsWeb) return {};
    try {
      final file = await _getSettingsFile();
      if (file == null || !await file.exists()) {
        return {};
      }
      final content = await file.readAsString();
      if (content.trim().isEmpty) return {};
      final data = jsonDecode(content) as Map<String, dynamic>;
      final list = (data['selected_tournament_types'] as List<dynamic>?) ?? [];
      return list.map((e) => e.toString()).toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void>? _pendingSave;

  Future<void> saveSelectedTournamentTypeNames(Set<String> typeNames) {
    _pendingSave = (_pendingSave ?? Future.value()).then((_) => _doSave(typeNames));
    return _pendingSave!;
  }

  Future<void> _doSave(Set<String> typeNames) async {
    if (kIsWeb) return;
    try {
      final file = await _getSettingsFile();
      if (file == null) return;
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      Map<String, dynamic> data = {};
      if (await file.exists()) {
        try {
          final content = await file.readAsString();
          if (content.trim().isNotEmpty) {
            data = jsonDecode(content) as Map<String, dynamic>;
          }
        } catch (_) {}
      }
      data['selected_tournament_types'] = typeNames.toList();
      
      final tmpFile = File('${file.path}.tmp');
      await tmpFile.writeAsString(jsonEncode(data), flush: true);
      await tmpFile.rename(file.path);
    } catch (_) {}
  }
}
