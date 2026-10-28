import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_surface_view/native_surface_view.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_app/data/database_service.dart';
import 'package:flutter_app/data/local_database.dart';
import 'package:flutter_app/services/playback_progress_service.dart';
import 'package:flutter_app/services/settings_service.dart';
import 'package:flutter_app/services/user_database_sync_service.dart';
import 'package:flutter_app/video/ytdlp/ytdlp_service.dart';
import 'package:flutter_app/video/ytdlp/test_ytdlp.dart';
import 'package:flutter_app/widgets/cloud_sync_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    MediaKit.ensureInitialized();
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      await windowManager.ensureInitialized();
    }
  });

  testWidgets('E2E: complete hermetic cloud sync flow: connect UI, save play time locally & in cloud, update sync time, and resume on Device B', (
    WidgetTester tester,
  ) async {
    final tempDirA = Directory.systemTemp.createTempSync('device_a_');
    final tempDirB = Directory.systemTemp.createTempSync('device_b_');

    // Start hermetic mock Supabase cloud server
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final cloudUrl = 'http://127.0.0.1:$port';

    final Map<String, Map<String, dynamic>> cloudPlaybackProgressTable = {};
    final Map<String, Map<String, dynamic>> cloudUserSettingsTable = {};

    server.listen((HttpRequest request) async {
      request.response.headers.contentType = ContentType.json;

      if (request.uri.path.contains('playback_progress')) {
        if (request.method == 'GET') {
          request.response.write(jsonEncode(cloudPlaybackProgressTable.values.toList()));
        } else if (request.method == 'POST') {
          final body = await utf8.decodeStream(request);
          if (body.isNotEmpty) {
            final decoded = jsonDecode(body);
            if (decoded is List) {
              for (final item in decoded) {
                final map = Map<String, dynamic>.from(item as Map);
                cloudPlaybackProgressTable[map['match_id']] = map;
              }
            } else if (decoded is Map) {
              final map = Map<String, dynamic>.from(decoded);
              cloudPlaybackProgressTable[map['match_id']] = map;
            }
          }
          request.response.write(jsonEncode(cloudPlaybackProgressTable.values.toList()));
        }
      } else if (request.uri.path.contains('user_settings')) {
        if (request.method == 'GET') {
          request.response.write(jsonEncode(cloudUserSettingsTable.values.toList()));
        } else if (request.method == 'POST') {
          final body = await utf8.decodeStream(request);
          if (body.isNotEmpty) {
            final decoded = jsonDecode(body);
            if (decoded is Map) {
              cloudUserSettingsTable[decoded['key']] = Map<String, dynamic>.from(decoded);
            }
          }
          request.response.write('[]');
        }
      } else {
        request.response.write('[]');
      }
      await request.response.close();
    });

    try {
      // =======================================================================
      // STEP 1: INITIAL SETUP FOR DEVICE A
      // =======================================================================
      final localSettingsPathA = '${tempDirA.path}/settings.json';
      final localProgressPathA = '${tempDirA.path}/progress.json';

      SettingsService.instance.customSettingsPath = localSettingsPathA;
      PlaybackProgressService.instance.resetForTesting();
      PlaybackProgressService.instance.customStoragePath = localProgressPathA;
      await UserDatabaseSyncService.instance.disconnect();

      DatabaseService.instance = LocalDatabaseService(
        localJsonPath: 'test/assets/mock_schedule.json',
      );
      final helperService = TestYtDlpService();
      final localVideo = helperService.resolveLocalVideoPath();
      final localAudio = localVideo.replaceAll('test_video.mp4', 'test_audio.mp4');
      YtDlpService.instance = TestYtDlpService(
        localVideoPath: localVideo,
        mockAudioUrl: localAudio,
        mockResolutions: [1080, 720, 480],
      );

      await DatabaseService.instance.initialize();
      await filterController.fetchData();

      // Launch App on Device A
      await tester.pumpWidget(const WttApp());
      await tester.pumpAndSettle();

      // =======================================================================
      // STEP 2: OPEN CLOUD SYNC UI & CONNECT TO HERMETIC CLOUD DATABASE
      // =======================================================================
      // Navigate to CloudSyncScreen via Sidebar tap
      final cloudSyncNavBtn = find.text('Cloud Sync');
      expect(cloudSyncNavBtn, findsOneWidget, reason: 'Cloud Sync button must be visible in sidebar');
      await tester.tap(cloudSyncNavBtn);
      await tester.pumpAndSettle();

      expect(find.byType(CloudSyncScreen), findsOneWidget);
      expect(find.text('Not Connected (Local Only)'), findsOneWidget);

      // Connect to hermetic mock cloud database
      await UserDatabaseSyncService.instance.connectWithCredentials(
        projectUrl: cloudUrl,
        anonKey: 'mock-test-key',
        projectRef: 'hermetic-cloud',
      );
      await tester.pumpAndSettle();

      expect(find.text('Connected to Personal Supabase'), findsOneWidget);
      expect(UserDatabaseSyncService.instance.isConnected, isTrue);

      // Pop back to main player view
      Navigator.of(tester.element(find.byType(CloudSyncScreen))).pop();
      await tester.pumpAndSettle();

      // =======================================================================
      // STEP 3: PLAY VIDEO, ADVANCE TIMELINE, AND PAUSE
      // =======================================================================
      final tournament = filterController.allTournaments.firstWhere((t) => t.name == 'China Smash');
      if (filterController.selectedTournamentId != tournament.id) {
        await filterController.selectTournament(tournament.id);
        await tester.pumpAndSettle();
      }

      final match = filterController.allMatches.firstWhere((m) => m.title.contains('Lin Shidong'));
      expect(match.offsetSeconds, 120, reason: 'Initial match offset should be 120s');

      filterController.selectMatch(match);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();

      final videoFinder = find.descendant(
        of: find.byType(VideoHero),
        matching: Platform.isAndroid ? find.byType(NativeSurfaceView) : find.byType(Video),
      );
      final dynamic videoWidget = tester.widget(videoFinder);
      final Player player = videoWidget.controller.player;

      // Watch to 250s (+130s into match) and pause
      await player.seek(const Duration(seconds: 250));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await player.pause();
      await tester.pump(const Duration(milliseconds: 500));

      // =======================================================================
      // STEP 4: ASSERT PLAY TIME SAVED BOTH LOCALLY AND IN CLOUD DATABASE
      // =======================================================================
      // Check 1: Local save
      final localFileA = File(localProgressPathA);
      expect(localFileA.existsSync(), isTrue, reason: 'Local progress file must exist on Device A');
      final localContentA = localFileA.readAsStringSync();
      expect(localContentA.contains('"position_seconds":250'), isTrue, reason: 'Local file must contain position 250s');

      // Check 2: Cloud database save
      expect(cloudPlaybackProgressTable.isNotEmpty, isTrue, reason: 'Progress must be pushed to hermetic cloud database');
      final cloudRecord = cloudPlaybackProgressTable.values.firstWhere((r) => r['position_seconds'] == 250);
      expect(cloudRecord['match_id'], match.id);
      expect(cloudRecord['position_seconds'], 250);
      expect(cloudRecord['youtube_id'], match.youtubeId);

      // Check 3: Real-time sync timestamp update in CloudSyncScreen
      isFullscreenNotifier.value = false;
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cloud Sync'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Last sync:'), findsOneWidget, reason: 'Live sync timestamp must be displayed');
      Navigator.of(tester.element(find.byType(CloudSyncScreen))).pop();
      await tester.pumpAndSettle();

      // =======================================================================
      // STEP 5: DEVICE B - RECONCILE PROGRESS & RESUME PLAYBACK
      // =======================================================================
      final localSettingsPathB = '${tempDirB.path}/settings.json';
      final localProgressPathB = '${tempDirB.path}/progress.json';

      SettingsService.instance.customSettingsPath = localSettingsPathB;
      PlaybackProgressService.instance.resetForTesting();
      PlaybackProgressService.instance.customStoragePath = localProgressPathB;

      // Device B starts with empty local progress file
      final localFileB = File(localProgressPathB);
      expect(localFileB.existsSync(), isFalse, reason: 'Device B must start without local progress');

      // Device B connects to cloud and syncs
      await UserDatabaseSyncService.instance.connectWithCredentials(
        projectUrl: cloudUrl,
        anonKey: 'mock-test-key',
        projectRef: 'hermetic-cloud',
      );

      // Verify Device B adopted the 250s position from the cloud
      expect(localFileB.existsSync(), isTrue, reason: 'Device B must save adopted progress to local disk');
      final posOnDeviceB = await PlaybackProgressService.instance.getResumePosition(
        matchId: match.id,
        defaultOffsetSeconds: match.offsetSeconds ?? 0,
        youtubeId: match.youtubeId,
      );
      expect(posOnDeviceB, 250, reason: 'Device B must resume at 250s adopted from cloud');

    } finally {
      await server.close(force: true);
      if (tempDirA.existsSync()) tempDirA.deleteSync(recursive: true);
      if (tempDirB.existsSync()) tempDirB.deleteSync(recursive: true);
    }
  });
}
