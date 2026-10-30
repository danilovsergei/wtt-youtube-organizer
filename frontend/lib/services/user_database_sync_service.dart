import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/prod_database.dart';
import 'log_service.dart';
import 'playback_progress_service.dart';
import 'settings_service.dart';

enum SyncStatus {
  disconnected,
  idle,
  syncing,
  paused,
  error,
}

class UserDatabaseSyncService extends ChangeNotifier {
  @visibleForTesting
  String? customCentralKeepaliveUrl;

  bool _isKeepaliveActive = false;
  bool get isKeepaliveActive => _isKeepaliveActive;

  Future<bool> _registerKeepalive(String projectUrl, String anonKey) async {
    try {
      final centralRpcUrl = customCentralKeepaliveUrl ??
          '${ProdDatabaseService.supabaseUrl}/rest/v1/rpc/register_sync_keepalive';
      final headers = {
        'apikey': ProdDatabaseService.supabasePublishableKey,
        'Authorization': 'Bearer ${ProdDatabaseService.supabasePublishableKey}',
        'Content-Type': 'application/json',
      };
      final body = jsonEncode({
        'p_url': projectUrl,
        'p_key': anonKey,
      });
      final res = await http.post(Uri.parse(centralRpcUrl), headers: headers, body: body);
      if (res.statusCode == 200) {
        _isKeepaliveActive = true;
        await SettingsService.instance.saveKeepaliveRegisteredUrl(projectUrl);
        LogService.instance.log('[KEEPALIVE] Registered sync project for daily keep-alive: 200 OK');
        notifyListeners();
        return true;
      } else {
        LogService.instance.log('[KEEPALIVE] Registration returned status: ${res.statusCode}');
      }
    } catch (e) {
      LogService.instance.log('Note: Failed to register keep-alive ($e)');
    }
    return false;
  }

  Future<bool> registerKeepaliveManually() async {
    if (_userProjectUrl == null || _userAnonKey == null) return false;
    return _registerKeepalive(_userProjectUrl!, _userAnonKey!);
  }
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

  String? get effectiveProjectRef {
    if (_projectRef != null && _projectRef!.isNotEmpty) return _projectRef;
    if (_userProjectUrl == null) return null;
    final uri = Uri.tryParse(_userProjectUrl!);
    if (uri == null) return null;
    final parts = uri.host.split('.');
    if (parts.isNotEmpty) return parts.first;
    return null;
  }
  String? get anonKey => _userAnonKey;

  @visibleForTesting
  void setClientForTesting(SupabaseClient client, {String? projectUrl, String? projectRef, bool clearProjectRef = false}) {
    _client = client;
    _userProjectUrl = projectUrl ?? 'https://mock.supabase.co';
    _userAnonKey = 'mock-key';
    _projectRef = clearProjectRef ? null : (projectRef ?? 'mock-ref');
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

        // Only register keep-alive if not yet registered for this project!
        final registeredUrl = await SettingsService.instance.loadKeepaliveRegisteredUrl();
        if (registeredUrl != null && registeredUrl == url) {
          _isKeepaliveActive = true;
          LogService.instance.log('[KEEPALIVE] Project $url is already registered for keep-alive.');
        } else {
          _isKeepaliveActive = false;
          LogService.instance.log('[KEEPALIVE] Project $url not yet registered. Registering on startup...');
          unawaited(_registerKeepalive(url, anonKey));
        }
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
    await _registerKeepalive(projectUrl, anonKey);
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

    _isKeepaliveActive = false;
    await SettingsService.instance.saveKeepaliveRegisteredUrl(null);
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
      await syncPlaybackProgress().timeout(const Duration(seconds: 8));
      await syncSettings().timeout(const Duration(seconds: 8));
      _lastSyncTime = DateTime.now();
      _status = SyncStatus.idle;
      LogService.instance.log('[SYNC] Full sync completed successfully');
    } catch (e, stack) {
      final errStr = e.toString();
      _lastError = errStr;
      if (isPausedError(errStr)) {
        _status = SyncStatus.paused;
        LogService.instance.log('[SYNC] Project is PAUSED by Supabase (7-day inactivity): $e');
      } else {
        _status = SyncStatus.error;
        LogService.instance.log('[SYNC] Sync error: $e\n$stack');
      }
    }
    notifyListeners();
  }

  static bool isPausedError(String error) {
    final lower = error.toLowerCase();
    return lower.contains('failed host lookup') ||
           lower.contains('name or service not known') ||
           lower.contains('paused') ||
           lower.contains('503');
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
