import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
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
import 'package:flutter_app/services/device_pairing_service.dart';
import 'package:flutter_app/video/ytdlp/ytdlp_service.dart';
import 'package:flutter_app/video/ytdlp/test_ytdlp.dart';
import 'package:flutter_app/widgets/linked_devices_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    MediaKit.ensureInitialized();
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      await windowManager.ensureInitialized();
    }
  });

  testWidgets(
    'E2E: Device Pairing workflow - Receive on TV, Link from Facilitating device, Transfer Cloud Sync',
    (WidgetTester tester) async {
      final tempDir = Directory.systemTemp.createTempSync('device_pair_e2e_');
      final localSettingsPath = '${tempDir.path}/settings.json';
      final localProgressPath = '${tempDir.path}/progress.json';

      // Mock central server
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      final mockCloudUrl = 'http://127.0.0.1:$port';

      Map<String, dynamic>? activeSessionRecord;

      server.listen((HttpRequest request) async {
        request.response.headers.contentType = ContentType.json;

        if (request.uri.path.contains('create_device_pairing')) {
          final body = await utf8.decodeStream(request);
          final map = jsonDecode(body);
          activeSessionRecord = {
            'session_id': 'sess-12345',
            'code': '789012',
            'device_name': map['p_device_name'] ?? 'Android TV',
            'status': 'pending',
            'payload': null,
            'expires_at': DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
          };
          request.response.write(jsonEncode(activeSessionRecord));
        } else if (request.uri.path.contains('get_device_pairing_info')) {
          final body = await utf8.decodeStream(request);
          final map = jsonDecode(body);
          if (activeSessionRecord != null && map['p_code'] == activeSessionRecord!['code']) {
            request.response.write(jsonEncode({
              'valid': true,
              'device_name': activeSessionRecord!['device_name'],
            }));
          } else {
            request.response.write(jsonEncode({'valid': false, 'error': 'Code not found'}));
          }
        } else if (request.uri.path.contains('fulfill_device_pairing')) {
          final body = await utf8.decodeStream(request);
          final map = jsonDecode(body);
          if (activeSessionRecord != null && map['p_code'] == activeSessionRecord!['code']) {
            activeSessionRecord!['status'] = 'fulfilled';
            activeSessionRecord!['payload'] = map['p_payload'];
            request.response.write(jsonEncode({'success': true}));
          } else {
            request.response.write(jsonEncode({'success': false, 'error': 'Not found'}));
          }
        } else if (request.uri.path.contains('claim_device_pairing')) {
          if (activeSessionRecord != null && activeSessionRecord!['status'] == 'fulfilled') {
            final payload = activeSessionRecord!['payload'];
            activeSessionRecord!['status'] = 'claimed';
            activeSessionRecord!['payload'] = null;
            request.response.write(jsonEncode({
              'status': 'claimed',
              'payload': payload,
            }));
          } else {
            request.response.write(jsonEncode({'status': 'pending'}));
          }
        } else {
          // Normal mock database responses
          request.response.write('[]');
        }
        await request.response.close();
      });

      try {
        SettingsService.instance.customSettingsPath = localSettingsPath;
        PlaybackProgressService.instance.resetForTesting();
        PlaybackProgressService.instance.customStoragePath = localProgressPath;
        DevicePairingService.instance.customRpcBaseUrl = '$mockCloudUrl/rest/v1/rpc';
        UserDatabaseSyncService.instance.customCentralKeepaliveUrl = '$mockCloudUrl/rest/v1/rpc/register_sync_keepalive';
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

        // Launch app
        await tester.pumpWidget(const WttApp());
        await tester.pumpAndSettle();

        // 1. Verify "Linked Devices" is accessible from sidebar
        final linkedDevicesBtn = find.text('Linked Devices');
        expect(linkedDevicesBtn, findsOneWidget);

        await tester.tap(linkedDevicesBtn);
        await tester.pumpAndSettle();
        expect(find.byType(LinkedDevicesScreen), findsOneWidget);

        // 2. Click "Show Pairing Code" (simulate Android TV waiting for link)
        final showCodeBtn = find.text('Show Pairing Code');
        expect(showCodeBtn, findsOneWidget);
        await tester.tap(showCodeBtn);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));

        // Verify pairing code is displayed
        expect(find.text('PAIRING CODE'), findsOneWidget);
        expect(find.text('789 - 012'), findsOneWidget);
        expect(find.text('Waiting for facilitating device...'), findsOneWidget);

        // 3. Simulate facilitating device (e.g. Phone or PC):
        // Fulfill the pairing session with user Cloud Sync credentials
        final ok = await DevicePairingService.instance.fulfillPairing('789012', {
          'action': 'cloud_sync',
          'project_url': 'http://127.0.0.1:$port',
          'anon_key': 'transferred-anon-key',
          'project_ref': 'transferred-ref',
        });
        expect(ok, isTrue);

        // Advance frames until TV polling loop claims credentials and renders device in list
        for (int i = 0; i < 15; i++) {
          await tester.pump(const Duration(milliseconds: 200));
          if (find.text('LINKED DEVICES').evaluate().isNotEmpty) {
            break;
          }
        }

        // 4. Verify linked device is rendered directly in the list (no blocking dialog, no redundant active badge)
        expect(find.text('LINKED DEVICES'), findsOneWidget);
        expect(find.text('WTT Client'), findsOneWidget);

        // 5. Verify UserDatabaseSyncService is now connected with transferred credentials
        expect(UserDatabaseSyncService.instance.isConnected, isTrue);
        expect(UserDatabaseSyncService.instance.projectUrl, 'http://127.0.0.1:$port');
        expect(UserDatabaseSyncService.instance.effectiveProjectRef, 'transferred-ref');

      } finally {
        await server.close(force: true);
        DevicePairingService.instance.customRpcBaseUrl = null;
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      }
    },
  );
}
