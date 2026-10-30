import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_app/services/user_database_sync_service.dart';
import 'package:flutter_app/services/playback_progress_service.dart';
import 'package:flutter_app/services/settings_service.dart';

void main() {
  group('UserDatabaseSyncService', () {
    late HttpServer server;
    late int port;
    late Directory tempDir;
    late SupabaseClient client;
    final List<Map<String, dynamic>> remotePlaybackRows = [];
    final List<Map<String, dynamic>> remoteSettingsRows = [];
    final List<Map<String, dynamic>> upsertedPlaybackRecords = [];

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('sync_test_');
      SettingsService.instance.customSettingsPath = '${tempDir.path}/test_settings.json';
      PlaybackProgressService.instance.resetForTesting();
      PlaybackProgressService.instance.customStoragePath = '${tempDir.path}/test_progress.json';

      remotePlaybackRows.clear();
      remoteSettingsRows.clear();
      upsertedPlaybackRecords.clear();

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;

      server.listen((HttpRequest request) async {
        request.response.headers.contentType = ContentType.json;

        if (request.uri.path.contains('playback_progress')) {
          if (request.method == 'GET') {
            request.response.write(jsonEncode(remotePlaybackRows));
          } else if (request.method == 'POST') {
            final body = await utf8.decodeStream(request);
            if (body.isNotEmpty) {
              final decoded = jsonDecode(body);
              if (decoded is List) {
                for (final item in decoded) {
                  upsertedPlaybackRecords.add(Map<String, dynamic>.from(item as Map));
                }
              } else if (decoded is Map) {
                upsertedPlaybackRecords.add(Map<String, dynamic>.from(decoded));
              }
            }
            request.response.write(jsonEncode(upsertedPlaybackRecords));
          }
        } else if (request.uri.path.contains('user_settings')) {
          if (request.method == 'GET') {
            request.response.write(jsonEncode(remoteSettingsRows));
          } else if (request.method == 'POST') {
            request.response.write('[]');
          }
        } else {
          request.response.write('[]');
        }
        await request.response.close();
      });

      client = SupabaseClient('http://127.0.0.1:$port', 'mock-key');
      UserDatabaseSyncService.instance.setClientForTesting(client, projectUrl: 'http://127.0.0.1:$port');
    });

    tearDown(() async {
      await server.close(force: true);
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('adopts remote progress when remote updated_at is newer than local', () async {
      // Remote has progress saved 10 minutes ago
      final remoteTime = DateTime.now().toUtc().add(const Duration(minutes: 10));
      remotePlaybackRows.add({
        'match_id': 'm_remote_newer',
        'youtube_id': 'yt_123',
        'position_seconds': 550,
        'default_offset_seconds': 100,
        'duration_seconds': 1000,
        'updated_at': remoteTime.toIso8601String(),
      });

      // Local has progress saved 20 minutes ago
      await PlaybackProgressService.instance.saveProgress(
        matchId: 'm_remote_newer',
        positionSeconds: 200,
        defaultOffsetSeconds: 100,
        matchDurationSeconds: 1000,
        youtubeId: 'yt_123',
      );

      // Run sync
      await UserDatabaseSyncService.instance.syncPlaybackProgress();

      // Assert that local adopted remote position (550s)
      final pos = await PlaybackProgressService.instance.getResumePosition(
        matchId: 'm_remote_newer',
        defaultOffsetSeconds: 100,
      );
      expect(pos, 550, reason: 'Newer remote progress should be adopted locally');
    });

    test('pushes local progress to remote when local updated_at is newer', () async {
      // Local has progress saved now
      await PlaybackProgressService.instance.saveProgress(
        matchId: 'm_local_newer',
        positionSeconds: 800,
        defaultOffsetSeconds: 100,
        matchDurationSeconds: 1200,
        youtubeId: 'yt_local',
      );

      // Remote has older progress
      remotePlaybackRows.add({
        'match_id': 'm_local_newer',
        'youtube_id': 'yt_local',
        'position_seconds': 300,
        'default_offset_seconds': 100,
        'duration_seconds': 1200,
        'updated_at': DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String(),
      });

      // Run sync
      await UserDatabaseSyncService.instance.syncPlaybackProgress();

      // Assert that local progress (800s) was pushed to remote
      expect(
        upsertedPlaybackRecords.any((r) => r['match_id'] == 'm_local_newer' && r['position_seconds'] == 800),
        isTrue,
        reason: 'Newer local progress must be pushed to remote',
      );
    });

    test('pushSingleMatchProgress performs background upsert', () async {
      final entry = PlaybackProgressEntry(
        positionSeconds: 450,
        defaultOffsetSeconds: 60,
        durationSeconds: 900,
        youtubeId: 'yt_direct',
      );

      await UserDatabaseSyncService.instance.pushSingleMatchProgress(entry, 'm_direct');

      expect(
        upsertedPlaybackRecords.any((r) => r['match_id'] == 'm_direct' && r['position_seconds'] == 450),
        isTrue,
        reason: 'pushSingleMatchProgress must upsert to playback_progress table',
      );
    });

    test('adopts remote settings if local settings are empty', () async {
      remoteSettingsRows.add({
        'key': 'selected_tournament_types',
        'value': ['smash', 'feeder'],
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

      await UserDatabaseSyncService.instance.syncSettings();

      final types = await SettingsService.instance.loadSelectedTournamentTypeNames();
      expect(types, containsAll(['smash', 'feeder']));
    });

    test('isPausedError accurately detects DNS NXDOMAIN, 503, and paused messages', () {
      expect(UserDatabaseSyncService.isPausedError('ClientException with SocketException: Failed host lookup: "foo.supabase.co"'), isTrue);
      expect(UserDatabaseSyncService.isPausedError('OS Error: Name or service not known, errno = -2'), isTrue);
      expect(UserDatabaseSyncService.isPausedError('PostgrestException: Project is paused by Supabase'), isTrue);
      expect(UserDatabaseSyncService.isPausedError('HTTP 503 Service Unavailable'), isTrue);
      expect(UserDatabaseSyncService.isPausedError('Database connection timeout'), isFalse);
      expect(UserDatabaseSyncService.isPausedError('Invalid JWT token'), isFalse);
    });

    test('effectiveProjectRef correctly extracts ref from stored ref or URL', () {
      UserDatabaseSyncService.instance.setClientForTesting(
        client,
        projectUrl: 'https://kbklcoospalxtmtalltm.supabase.co',
        projectRef: 'kbklcoospalxtmtalltm',
      );
      expect(UserDatabaseSyncService.instance.effectiveProjectRef, 'kbklcoospalxtmtalltm');

      UserDatabaseSyncService.instance.setClientForTesting(
        client,
        projectUrl: 'https://myref123.supabase.co',
        clearProjectRef: true,
      );
      expect(UserDatabaseSyncService.instance.effectiveProjectRef, 'myref123');
    });
  });
}
