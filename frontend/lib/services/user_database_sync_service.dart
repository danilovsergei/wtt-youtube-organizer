import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'log_service.dart';
import 'playback_progress_service.dart';
import 'settings_service.dart';

enum SyncStatus {
  disconnected,
  idle,
  syncing,
  error,
}

class UserDatabaseSyncService extends ChangeNotifier {
  static final UserDatabaseSyncService instance = UserDatabaseSyncService._();
  UserDatabaseSyncService._();

  SupabaseClient? _client;
  String? _userProjectUrl;
  String? _userAnonKey;
  String? _projectRef;

  SyncStatus _status = SyncStatus.disconnected;
  SyncStatus get status => _status;
  bool get isConnected => _client != null && _userProjectUrl != null;

  DateTime? _lastSyncTime;
  DateTime? get lastSyncTime => _lastSyncTime;

  String? _lastError;
  String? get lastError => _lastError;

  String? get projectUrl => _userProjectUrl;
  String? get projectRef => _projectRef;
  String? get anonKey => _userAnonKey;

  @visibleForTesting
  void setClientForTesting(SupabaseClient client, {String? projectUrl, String? projectRef}) {
    _client = client;
    _userProjectUrl = projectUrl ?? 'https://mock.supabase.co';
    _userAnonKey = 'mock-key';
    _projectRef = projectRef ?? 'mock-ref';
    _status = SyncStatus.idle;
    notifyListeners();
  }

  Future<void> initialize() async {
    final config = await SettingsService.instance.loadUserSupabaseConfig();
    final url = config['url'];
    final anonKey = config['anon_key'];
    final ref = config['project_ref'];

    if (url != null && anonKey != null && url.isNotEmpty && anonKey.isNotEmpty) {
      _userProjectUrl = url;
      _userAnonKey = anonKey;
      _projectRef = ref;
      try {
        _client = SupabaseClient(url, anonKey);
        _status = SyncStatus.idle;
        LogService.instance.log('[SYNC] Initialized with user Supabase project: $url');
        unawaited(syncAll());
      } catch (e) {
        _status = SyncStatus.error;
        _lastError = e.toString();
        LogService.instance.log('[SYNC] Failed to initialize SupabaseClient: $e');
      }
    } else {
      _status = SyncStatus.disconnected;
    }
    notifyListeners();
  }

  Future<void> connectWithCredentials({
    required String projectUrl,
    required String anonKey,
    String? projectRef,
  }) async {
    _userProjectUrl = projectUrl;
    _userAnonKey = anonKey;
    _projectRef = projectRef;
    _client = SupabaseClient(projectUrl, anonKey);
    _status = SyncStatus.idle;
    _lastError = null;

    await SettingsService.instance.saveUserSupabaseConfig(
      url: projectUrl,
      anonKey: anonKey,
      projectRef: projectRef,
    );

    LogService.instance.log('[SYNC] Connected to user Supabase project: $projectUrl');
    notifyListeners();
    await syncAll();
  }

  Future<void> disconnect() async {
    _client = null;
    _userProjectUrl = null;
    _userAnonKey = null;
    _projectRef = null;
    _status = SyncStatus.disconnected;
    _lastError = null;
    _lastSyncTime = null;

    await SettingsService.instance.saveUserSupabaseConfig(
      url: null,
      anonKey: null,
      projectRef: null,
    );

    LogService.instance.log('[SYNC] Disconnected from user Supabase project');
    notifyListeners();
  }

  Future<void> syncAll() async {
    if (!isConnected) return;
    _status = SyncStatus.syncing;
    _lastError = null;
    notifyListeners();

    try {
      await syncPlaybackProgress();
      await syncSettings();
      _lastSyncTime = DateTime.now();
      _status = SyncStatus.idle;
      LogService.instance.log('[SYNC] Full sync completed successfully');
    } catch (e, stack) {
      _status = SyncStatus.error;
      _lastError = e.toString();
      LogService.instance.log('[SYNC] Sync error: $e\n$stack');
    }
    notifyListeners();
  }

  Future<void> syncPlaybackProgress() async {
    if (_client == null) return;
    LogService.instance.log('[SYNC] Reconciling playback progress with remote...');

    // 1. Fetch remote progress
    final List<dynamic> remoteData = await _client!
        .from('playback_progress')
        .select();

    final remoteRows = remoteData.cast<Map<String, dynamic>>();
    final remoteMap = <String, Map<String, dynamic>>{};
    for (final row in remoteRows) {
      final matchId = row['match_id']?.toString();
      if (matchId != null) {
        remoteMap[matchId] = row;
      }
    }

    // 2. Compare with local entries
    final localEntries = PlaybackProgressService.instance.getAllMetadataEntries();
    final toPush = <Map<String, dynamic>>[];

    // Check remote vs local
    for (final entry in remoteMap.entries) {
      final matchId = entry.key;
      final remoteRow = entry.value;
      final remoteUpdatedAt = DateTime.tryParse(remoteRow['updated_at']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);

      final localEntry = localEntries[matchId];
      if (localEntry == null || remoteUpdatedAt.isAfter(localEntry.updatedAt)) {
        // Remote is newer or brand new: adopt locally!
        LogService.instance.log('[SYNC] Adopting remote progress for $matchId (remote: $remoteUpdatedAt > local: ${localEntry?.updatedAt})');
        await PlaybackProgressService.instance.adoptRemoteProgress(
          matchId,
          PlaybackProgressEntry.fromJson(remoteRow),
        );
      } else if (localEntry.updatedAt.isAfter(remoteUpdatedAt)) {
        // Local is newer: queue to push
        toPush.add(localEntry.toJson()..['match_id'] = matchId);
      }
    }

    // Check local entries that do not exist in remote
    for (final localEntry in localEntries.entries) {
      if (!remoteMap.containsKey(localEntry.key)) {
        toPush.add(localEntry.value.toJson()..['match_id'] = localEntry.key);
      }
    }

    // 3. Batch push any local newer records to remote
    if (toPush.isNotEmpty) {
      LogService.instance.log('[SYNC] Pushing ${toPush.length} local progress records to remote...');
      await _client!.from('playback_progress').upsert(toPush);
    }
  }

  Future<void> syncSettings() async {
    if (_client == null) return;
    LogService.instance.log('[SYNC] Syncing user settings with remote...');

    try {
      final List<dynamic> remoteData = await _client!
          .from('user_settings')
          .select()
          .eq('key', 'selected_tournament_types');

      final localTypes = await SettingsService.instance.loadSelectedTournamentTypeNames();

      if (remoteData.isNotEmpty) {
        final row = remoteData.first as Map<String, dynamic>;
        final remoteValue = (row['value'] as List<dynamic>?)?.map((e) => e.toString()).toSet() ?? {};

        if (localTypes.isEmpty && remoteValue.isNotEmpty) {
          LogService.instance.log('[SYNC] Adopting remote settings: $remoteValue');
          await SettingsService.instance.saveSelectedTournamentTypeNames(remoteValue);
        } else if (localTypes.isNotEmpty) {
          await _client!.from('user_settings').upsert({
            'key': 'selected_tournament_types',
            'value': localTypes.toList(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          });
        }
      } else if (localTypes.isNotEmpty) {
        await _client!.from('user_settings').upsert({
          'key': 'selected_tournament_types',
          'value': localTypes.toList(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
    } catch (e) {
      LogService.instance.log('[SYNC] Settings sync error: $e');
    }
  }

  Future<void> pushSingleMatchProgress(PlaybackProgressEntry entry, String matchId) async {
    if (!isConnected || _client == null) return;
    try {
      await _client!.from('playback_progress').upsert({
        'match_id': matchId,
        'youtube_id': entry.youtubeId,
        'position_seconds': entry.positionSeconds,
        'default_offset_seconds': entry.defaultOffsetSeconds,
        'duration_seconds': entry.durationSeconds,
        'updated_at': entry.updatedAt.toUtc().toIso8601String(),
      });
      _lastSyncTime = DateTime.now();
      notifyListeners();
      LogService.instance.log('[SYNC] Successfully pushed progress for $matchId to remote (pos=${entry.positionSeconds}s)');
    } catch (e) {
      LogService.instance.log('[SYNC] Failed to push progress for $matchId: $e');
    }
  }
}
