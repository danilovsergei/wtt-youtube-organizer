import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
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

  testWidgets(
    'E2E: Paused Supabase project detection, sidebar PAUSED indicator, copy restore link, and keep-alive card',
    (WidgetTester tester) async {
      final tempDir = Directory.systemTemp.createTempSync('keepalive_e2e_');
      final localSettingsPath = '${tempDir.path}/settings.json';
      final localProgressPath = '${tempDir.path}/progress.json';

      // Hermetic mock server
      bool isPaused = false;
      int keepaliveRegistrationCount = 0;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      final mockCloudUrl = 'http://127.0.0.1:$port';

      server.listen((HttpRequest request) async {
        request.response.headers.contentType = ContentType.json;

        if (request.uri.path.contains('register_sync_keepalive')) {
          keepaliveRegistrationCount++;
          request.response.statusCode = HttpStatus.ok;
          request.response.write('{"status": "ok"}');
        } else if (isPaused) {
          // When project is paused by Supabase
          request.response.statusCode = HttpStatus.serviceUnavailable;
          request.response.write('{"message": "Project is paused by Supabase", "code": "503"}');
        } else {
          // Normal active database response
          request.response.statusCode = HttpStatus.ok;
          request.response.write('[]');
        }
        await request.response.close();
      });

      try {
        // Initialize services with isolated test paths
        SettingsService.instance.customSettingsPath = localSettingsPath;
        PlaybackProgressService.instance.resetForTesting();
        PlaybackProgressService.instance.customStoragePath = localProgressPath;
        UserDatabaseSyncService.instance.customCentralKeepaliveUrl =
            '$mockCloudUrl/rest/v1/rpc/register_sync_keepalive';
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

        // Launch Application
        await tester.pumpWidget(const WttApp());
        await tester.pumpAndSettle();

        // =====================================================================
        // STEP 1: INITIAL STATE & CONNECTING CLOUD SYNC
        // =====================================================================
        final cloudSyncBtn = find.text('Cloud Sync');
        expect(cloudSyncBtn, findsOneWidget);
        expect(find.text('Offline / Local only'), findsOneWidget);

        // Open CloudSyncScreen
        await tester.tap(cloudSyncBtn);
        await tester.pumpAndSettle();
        expect(find.byType(CloudSyncScreen), findsOneWidget);

        // Connect with credentials
        await UserDatabaseSyncService.instance.connectWithCredentials(
          projectUrl: mockCloudUrl,
          anonKey: 'mock-anon-key',
          projectRef: 'kbklcoospalxtmtalltm',
        );
        await tester.pumpAndSettle();

        // Verify connected state
        expect(find.text('Connected to Personal Supabase'), findsOneWidget);

        // Verify Keep-Alive status card is displayed and shows ACTIVE
        expect(find.text('Keep-Alive (7-Day Pause Prevention)'), findsOneWidget);
        expect(find.text('ACTIVE'), findsOneWidget);
        expect(UserDatabaseSyncService.instance.isKeepaliveActive, isTrue);

        // Close CloudSyncScreen back to home
        Navigator.of(tester.element(find.byType(CloudSyncScreen))).pop();
        await tester.pumpAndSettle();

        // Main sidebar button should now show Connected to Supabase
        expect(find.text('Connected to Supabase'), findsOneWidget);

        // =====================================================================
        // STEP 2: SIMULATE SUPABASE PROJECT PAUSED (7-DAY INACTIVITY)
        // =====================================================================
        isPaused = true; // Supabase suspends database
        await UserDatabaseSyncService.instance.syncAll();
        await tester.pumpAndSettle();

        // Verify service detects paused state
        expect(UserDatabaseSyncService.instance.status, SyncStatus.paused);

        // Verify sidebar button shows amber PAUSED badge and 'Paused (Action Required)'
        expect(find.text('PAUSED'), findsWidgets);
        expect(find.text('Paused (Action Required)'), findsOneWidget);

        // =====================================================================
        // STEP 3: OPEN CLOUD SYNC & VERIFY PAUSED CARD + COPY RESTORE LINK
        // =====================================================================
        await tester.tap(cloudSyncBtn);
        await tester.pumpAndSettle();

        // Verify Amber Paused Card
        expect(find.text('Supabase Project is Paused (Inactive 7+ Days)'), findsOneWidget);
        expect(find.text('Restore in Dashboard'), findsOneWidget);
        expect(find.text('Copy Link'), findsOneWidget);
        expect(find.text('Check Again'), findsOneWidget);

        // Intercept SystemChannels.platform to verify clipboard interactions hermetically
        String? copiedClipboardText;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (MethodCall methodCall) async {
            if (methodCall.method == 'Clipboard.setData') {
              copiedClipboardText = (methodCall.arguments as Map)['text'] as String?;
              return null;
            } else if (methodCall.method == 'Clipboard.getData') {
              return {'text': copiedClipboardText};
            }
            return null;
          },
        );

        // Tap 'Copy Link' button
        final copyBtn = find.text('Copy Link');
        expect(copyBtn, findsOneWidget);
        await tester.tap(copyBtn);
        await tester.pumpAndSettle();

        // Verify confirmation toast appeared
        expect(find.textContaining('Dashboard restore link copied to clipboard!'), findsOneWidget);

        // Verify copied URL
        expect(
          copiedClipboardText,
          'https://supabase.com/dashboard/project/kbklcoospalxtmtalltm',
          reason: 'Copied link must lead directly to the user project dashboard',
        );

        // =====================================================================
        // STEP 4: SIMULATE RESTORATION & "CHECK AGAIN"
        // =====================================================================
        isPaused = false; // User clicked "Restore project" in Supabase dashboard
        final checkAgainBtn = find.text('Check Again');
        expect(checkAgainBtn, findsOneWidget);
        await tester.tap(checkAgainBtn);
        await tester.pumpAndSettle();

        // Verify status returned to connected
        expect(find.text('Connected to Personal Supabase'), findsOneWidget);
        expect(UserDatabaseSyncService.instance.status, SyncStatus.idle);

        // Close screen
        Navigator.of(tester.element(find.byType(CloudSyncScreen))).pop();
        await tester.pumpAndSettle();

        // Sidebar button should return to green Connected to Supabase
        expect(find.text('Connected to Supabase'), findsOneWidget);
        expect(find.text('PAUSED'), findsNothing);

        // =====================================================================
        // STEP 5: APP RESTART THROTTLING (NO REDUNDANT KEEP-ALIVE RPC CALLS)
        // =====================================================================
        final countBeforeRestart = keepaliveRegistrationCount;
        await UserDatabaseSyncService.instance.initialize();
        await tester.pumpAndSettle();

        // Assert no new registration call was made because it is already registered
        expect(
          keepaliveRegistrationCount,
          countBeforeRestart,
          reason: 'Keep-alive registration must be skipped on startup if already registered',
        );
        expect(UserDatabaseSyncService.instance.isKeepaliveActive, isTrue);

      } finally {
        await server.close(force: true);
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      }
    },
  );
}
