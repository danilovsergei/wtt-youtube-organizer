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

  Future<Map<String, dynamic>> _readSettingsJson() async {
    if (kIsWeb) return {};
    try {
      final file = await _getSettingsFile();
      if (file == null || !await file.exists()) return {};
      final content = await file.readAsString();
      if (content.trim().isEmpty) return {};
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<Set<String>> loadSelectedTournamentTypeNames() async {
    final data = await _readSettingsJson();
    final list = (data['selected_tournament_types'] as List<dynamic>?) ?? [];
    return list.map((e) => e.toString()).toSet();
  }

  Future<Map<String, String?>> loadUserSupabaseConfig() async {
    final data = await _readSettingsJson();
    return {
      'url': data['user_supabase_url'] as String?,
      'anon_key': data['user_supabase_anon_key'] as String?,
      'project_ref': data['user_supabase_project_ref'] as String?,
    };
  }

  Future<void>? _pendingSave;

  Future<void> saveSelectedTournamentTypeNames(Set<String> typeNames) {
    _pendingSave = (_pendingSave ?? Future.value()).then((_) => _doSaveTypes(typeNames));
    return _pendingSave!;
  }

  Future<void> saveUserSupabaseConfig({
    required String? url,
    required String? anonKey,
    String? projectRef,
  }) {
    _pendingSave = (_pendingSave ?? Future.value()).then((_) => _doSaveConfig(url, anonKey, projectRef));
    return _pendingSave!;
  }

  Future<String?> loadKeepaliveRegisteredUrl() async {
    final data = await _readSettingsJson();
    return data['keepalive_registered_url'] as String?;
  }

  Future<void> saveKeepaliveRegisteredUrl(String? url) {
    _pendingSave = (_pendingSave ?? Future.value()).then((_) => _doSaveKeepalive(url));
    return _pendingSave!;
  }

  Future<void> _doSaveTypes(Set<String> typeNames) async {
    if (kIsWeb) return;
    try {
      final file = await _getSettingsFile();
      if (file == null) return;
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final data = await _readSettingsJson();
      data['selected_tournament_types'] = typeNames.toList();

      final tmpFile = File('${file.path}.tmp');
      await tmpFile.writeAsString(jsonEncode(data), flush: true);
      await tmpFile.rename(file.path);
    } catch (_) {}
  }

  Future<void> _doSaveConfig(String? url, String? anonKey, String? projectRef) async {
    if (kIsWeb) return;
    try {
      final file = await _getSettingsFile();
      if (file == null) return;
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final data = await _readSettingsJson();
      if (url != null) {
        data['user_supabase_url'] = url;
      } else {
        data.remove('user_supabase_url');
      }
      if (anonKey != null) {
        data['user_supabase_anon_key'] = anonKey;
      } else {
        data.remove('user_supabase_anon_key');
      }
      if (projectRef != null) {
        data['user_supabase_project_ref'] = projectRef;
      } else {
        data.remove('user_supabase_project_ref');
      }

      final tmpFile = File('${file.path}.tmp');
      await tmpFile.writeAsString(jsonEncode(data), flush: true);
      await tmpFile.rename(file.path);
    } catch (_) {}
  }

  Future<void> _doSaveKeepalive(String? url) async {
    if (kIsWeb) return;
    try {
      final file = await _getSettingsFile();
      if (file == null) return;
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final data = await _readSettingsJson();
      if (url != null) {
        data['keepalive_registered_url'] = url;
      } else {
        data.remove('keepalive_registered_url');
      }

      final tmpFile = File('${file.path}.tmp');
      await tmpFile.writeAsString(jsonEncode(data), flush: true);
      await tmpFile.rename(file.path);
    } catch (_) {}
  }
}
