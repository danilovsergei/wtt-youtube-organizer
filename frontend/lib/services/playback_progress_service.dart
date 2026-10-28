import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'log_service.dart';
import 'user_database_sync_service.dart';

class PlaybackProgressEntry {
  final int positionSeconds;
  final int defaultOffsetSeconds;
  final int? durationSeconds;
  final String? youtubeId;
  final DateTime updatedAt;

  PlaybackProgressEntry({
    required this.positionSeconds,
    required this.defaultOffsetSeconds,
    this.durationSeconds,
    this.youtubeId,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().toUtc();

  Map<String, dynamic> toJson() => {
        'position_seconds': positionSeconds,
        'default_offset_seconds': defaultOffsetSeconds,
        if (durationSeconds != null) 'duration_seconds': durationSeconds,
        if (youtubeId != null) 'youtube_id': youtubeId,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory PlaybackProgressEntry.fromJson(Map<String, dynamic> json) {
    return PlaybackProgressEntry(
      positionSeconds: json['position_seconds'] as int? ?? 0,
      defaultOffsetSeconds: json['default_offset_seconds'] as int? ?? 0,
      durationSeconds: json['duration_seconds'] as int?,
      youtubeId: json['youtube_id'] as String?,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

class PlaybackProgressService extends ChangeNotifier {
  static final PlaybackProgressService instance = PlaybackProgressService._();
  PlaybackProgressService._();

  static const MethodChannel _channel = MethodChannel('wtt/settings');

  @visibleForTesting
  String? customStoragePath;

  final Map<String, int> _progressCache = {};
  final Map<String, PlaybackProgressEntry> _metadataCache = {};
  bool _isLoaded = false;
  final Set<String> _loggedMisses = {};

  @visibleForTesting
  void resetForTesting() {
    _progressCache.clear();
    _metadataCache.clear();
    _isLoaded = false;
    customStoragePath = null;
    _loggedMisses.clear();
    notifyListeners();
  }

  Future<File?> _getFile() async {
    if (kIsWeb) return null;

    if (customStoragePath != null) {
      return File(customStoragePath!);
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
        } catch (e) {
          LogService.instance.log('[PROGRESS] Failed to create dir ${dir.path}: $e');
        }
      }
      return File('${dir.path}/playback_progress.json');
    }

    if (Platform.isAndroid) {
      String? dirPath;
      try {
        dirPath = await _channel.invokeMethod<String>('getFilesDir');
      } catch (e) {
        LogService.instance.log('[PROGRESS] getFilesDir error: $e');
      }

      dirPath ??= '/data/user/0/com.example.flutter_app/files';
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        try {
          await dir.create(recursive: true);
        } catch (_) {
          final fallback = Directory('/data/data/com.example.flutter_app/files');
          try {
            await fallback.create(recursive: true);
            return File('${fallback.path}/playback_progress.json');
          } catch (_) {
            return null;
          }
        }
      }
      return File('${dir.path}/playback_progress.json');
    }

    return null;
  }

  Future<void> loadProgress() async {
    if (_isLoaded) return;
    _isLoaded = true;
    if (kIsWeb) return;

    try {
      final file = await _getFile();
      final exists = file != null && await file.exists();
      LogService.instance.log('[PROGRESS] loadProgress: file=${file?.path}, exists=$exists');

      if (file != null && exists) {
        final content = await file.readAsString();
        LogService.instance.log('[PROGRESS] Raw file content (${content.length} chars): ${content.trim().isEmpty ? "<EMPTY>" : content}');
        if (content.trim().isNotEmpty) {
          final decoded = jsonDecode(content);
          if (decoded is Map<String, dynamic>) {
            for (final entry in decoded.entries) {
              final val = entry.value;
              if (val is int) {
                _progressCache[entry.key] = val;
              } else if (val is Map<String, dynamic>) {
                final progressEntry = PlaybackProgressEntry.fromJson(val);
                _progressCache[entry.key] = progressEntry.positionSeconds;
                _metadataCache[entry.key] = progressEntry;
                if (progressEntry.youtubeId != null && progressEntry.youtubeId!.isNotEmpty) {
                  final compositeKey = '${progressEntry.youtubeId}_${progressEntry.defaultOffsetSeconds}';
                  _progressCache[compositeKey] = progressEntry.positionSeconds;
                }
              } else if (val is Map && val['position_seconds'] is int) {
                final pos = val['position_seconds'] as int;
                _progressCache[entry.key] = pos;
                final yt = val['youtube_id'] as String?;
                final off = val['default_offset_seconds'] as int?;
                if (yt != null && off != null) {
                  _progressCache['${yt}_$off'] = pos;
                }
              }
            }
          }
        }
      }
      LogService.instance.log('[PROGRESS] loadProgress COMPLETE: loaded ${_progressCache.length} entries: $_progressCache');
    } catch (e, stack) {
      LogService.instance.log('[PROGRESS] loadProgress ERROR: $e\n$stack');
    }
    notifyListeners();
  }

  Future<int> getResumePosition({
    required String? matchId,
    required int defaultOffsetSeconds,
    int? matchDurationSeconds,
    String? youtubeId,
  }) async {
    if (matchId == null || matchId.isEmpty) return defaultOffsetSeconds;
    if (!_isLoaded) {
      await loadProgress();
    }

    final fallbackKey = youtubeId != null ? '${youtubeId}_$defaultOffsetSeconds' : null;
    final savedPos = _progressCache[matchId] ??
        (fallbackKey != null ? _progressCache[fallbackKey] : null);

    LogService.instance.log('[PROGRESS] getResumePosition: matchId=$matchId, fallbackKey=$fallbackKey, savedPos=$savedPos, defaultOffset=$defaultOffsetSeconds');

    if (savedPos == null) return defaultOffsetSeconds;

    // Must be at least the initial match offset
    if (savedPos < defaultOffsetSeconds) return defaultOffsetSeconds;

    // Check completion (> 95% watched)
    if (matchDurationSeconds != null && matchDurationSeconds > 0) {
      final matchEnd = defaultOffsetSeconds + matchDurationSeconds;
      final ninetyFivePercent = defaultOffsetSeconds + (matchDurationSeconds * 0.95);
      if (savedPos >= ninetyFivePercent || savedPos >= matchEnd) {
        LogService.instance.log('[PROGRESS] getResumePosition: match completed ($savedPos >= $ninetyFivePercent), restarting from $defaultOffsetSeconds');
        return defaultOffsetSeconds;
      }
    }

    return savedPos;
  }

  /// Returns progress ratio (0.01 - 0.95) if match is in progress, or null if unstarted/finished.
  double? getProgressRatio({
    required String matchId,
    required int defaultOffsetSeconds,
    int? matchDurationSeconds,
    String? youtubeId,
  }) {
    final fallbackKey = youtubeId != null ? '${youtubeId}_$defaultOffsetSeconds' : null;
    final savedPos = _progressCache[matchId] ??
        (fallbackKey != null ? _progressCache[fallbackKey] : null);

    if (savedPos != null) {
      final watchedInMatch = savedPos - defaultOffsetSeconds;
      final double ratio;
      if (matchDurationSeconds == null || matchDurationSeconds <= 0) {
        ratio = 0.5;
      } else {
        ratio = watchedInMatch / matchDurationSeconds;
      }

      if (ratio >= 0.95 || ratio <= 0.0) {
        return null;
      }
      final clamped = ratio.clamp(0.01, 0.95);
      final logKey = '$matchId:$savedPos';
      if (!_loggedMisses.contains(logKey)) {
        _loggedMisses.add(logKey);
        LogService.instance.log('[PROGRESS] getProgressRatio HIT: matchId=$matchId (key=$fallbackKey) -> pos=$savedPos, ratio=${(clamped * 100).round()}%');
      }
      return clamped;
    } else if (_progressCache.isNotEmpty) {
      final missKey = '$matchId:$fallbackKey';
      if (!_loggedMisses.contains(missKey)) {
        _loggedMisses.add(missKey);
        LogService.instance.log('[PROGRESS] getProgressRatio MISS: queried matchId=$matchId, fallbackKey=$fallbackKey. Cache has ${_progressCache.length} keys: ${_progressCache.keys.toList()}');
      }
    }

    return null;
  }

  Map<String, PlaybackProgressEntry> getAllMetadataEntries() {
    return Map.unmodifiable(_metadataCache);
  }

  PlaybackProgressEntry? getMetadata(String matchId) {
    return _metadataCache[matchId];
  }

  Future<void> adoptRemoteProgress(String matchId, PlaybackProgressEntry entry) {
    _isLoaded = true;
    _progressCache[matchId] = entry.positionSeconds;
    _metadataCache[matchId] = entry;
    if (entry.youtubeId != null && entry.youtubeId!.isNotEmpty) {
      final compositeKey = '${entry.youtubeId}_${entry.defaultOffsetSeconds}';
      _progressCache[compositeKey] = entry.positionSeconds;
      _metadataCache[compositeKey] = entry;
    }
    notifyListeners();
    _pendingSave = (_pendingSave ?? Future.value()).then((_) => _doSave());
    return _pendingSave!;
  }

  Future<void>? _pendingSave;

  Future<void> saveProgress({
    required String? matchId,
    required int positionSeconds,
    required int defaultOffsetSeconds,
    int? matchDurationSeconds,
    String? youtubeId,
  }) {
    if (matchId == null || matchId.isEmpty) return Future.value();
    if (positionSeconds < defaultOffsetSeconds) return Future.value();

    _progressCache[matchId] = positionSeconds;
    final entry = PlaybackProgressEntry(
      positionSeconds: positionSeconds,
      defaultOffsetSeconds: defaultOffsetSeconds,
      durationSeconds: matchDurationSeconds,
      youtubeId: youtubeId,
    );
    _metadataCache[matchId] = entry;

    if (youtubeId != null && youtubeId.isNotEmpty) {
      final compositeKey = '${youtubeId}_$defaultOffsetSeconds';
      _progressCache[compositeKey] = positionSeconds;
      _metadataCache[compositeKey] = entry;
    }

    LogService.instance.log('[PROGRESS] saveProgress: matchId=$matchId, yt=$youtubeId, defOffset=$defaultOffsetSeconds, pos=$positionSeconds');
    notifyListeners();
    _pendingSave = (_pendingSave ?? Future.value()).then((_) => _doSave());

    // Non-blocking cloud sync if user configured personal Supabase database
    UserDatabaseSyncService.instance.pushSingleMatchProgress(entry, matchId);

    return _pendingSave!;
  }

  Future<void> clearProgress(String matchId, {String? youtubeId, int? defaultOffsetSeconds}) {
    _progressCache.remove(matchId);
    _metadataCache.remove(matchId);
    if (youtubeId != null && defaultOffsetSeconds != null) {
      final compositeKey = '${youtubeId}_$defaultOffsetSeconds';
      _progressCache.remove(compositeKey);
      _metadataCache.remove(compositeKey);
    }
    LogService.instance.log('[PROGRESS] clearProgress: matchId=$matchId, yt=$youtubeId');
    notifyListeners();
    _pendingSave = (_pendingSave ?? Future.value()).then((_) => _doSave());
    return _pendingSave!;
  }

  Future<void> _doSave() async {
    if (kIsWeb) return;
    try {
      final file = await _getFile();
      if (file == null) {
        LogService.instance.log('[PROGRESS] _doSave: file is null!');
        return;
      }
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final data = <String, dynamic>{};
      for (final entry in _progressCache.entries) {
        final meta = _metadataCache[entry.key];
        if (meta != null) {
          data[entry.key] = meta.toJson();
        } else {
          data[entry.key] = {
            'position_seconds': entry.value,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          };
        }
      }

      final tmpFile = File('${file.path}.tmp');
      await tmpFile.writeAsString(jsonEncode(data), flush: true);
      await tmpFile.rename(file.path);
      LogService.instance.log('[PROGRESS] _doSave SUCCESS: wrote ${_progressCache.length} entries to ${file.path} (${await file.length()} bytes)');
    } catch (e, stack) {
      LogService.instance.log('[PROGRESS] _doSave ERROR: $e\n$stack');
    }
  }
}
