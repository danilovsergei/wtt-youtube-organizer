import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_app/data/database_service.dart';
import 'package:flutter_app/data/local_database.dart';
import 'package:flutter_app/video/ytdlp/ytdlp_service.dart';
import 'package:flutter_app/video/ytdlp/test_ytdlp.dart';

final Uint8List _transparentPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _TestHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _MockHttpClient();
}

class _MockHttpClient implements HttpClient {
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;
  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials credentials) {}
  @override
  void addProxyCredentials(String host, int port, String realm, HttpClientCredentials credentials) {}
  @override
  set authenticate(Future<bool> Function(Uri url, String scheme, String? realm)? f) {}
  @override
  set authenticateProxy(Future<bool> Function(String host, int port, String scheme, String? realm)? f) {}
  @override
  set badCertificateCallback(bool Function(X509Certificate cert, String host, int port)? callback) {}
  @override
  set findProxy(String Function(Uri url)? f) {}
  @override
  void close({bool force = false}) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _MockHttpClientRequest();
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async => _MockHttpClientRequest();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpClientRequest implements HttpClientRequest {
  @override
  final HttpHeaders headers = _MockHttpHeaders();
  @override
  Future<HttpClientResponse> close() async => _MockHttpClientResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpClientResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  int get contentLength => _transparentPng.length;
  @override
  HttpClientResponseCompressionState get compressionState => HttpClientResponseCompressionState.notCompressed;
  @override
  final HttpHeaders headers = _MockHttpHeaders();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([_transparentPng]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    HttpOverrides.global = _TestHttpOverrides();
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();
  });

  testWidgets('Desktop E2E: opens tournament, selects match, verifies correct start time seeking and playback', (
    WidgetTester tester,
  ) async {
    // 1. Configure hermetic offline services pointing to local assets
    DatabaseService.instance = LocalDatabaseService(
      localJsonPath: 'test/assets/mock_schedule.json',
    );
    YtDlpService.instance = TestYtDlpService(
      localVideoPath: 'test/assets/test_video.mp4',
      mockResolutions: [1080, 720, 480],
    );

    // 2. Initialize local database and pre-load schedule
    await DatabaseService.instance.initialize();
    await filterController.fetchData();

    // 3. Launch full desktop app
    await tester.pumpWidget(const WttApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 4. Verify initial default tournament & match loaded
    expect(find.text('Tournaments'), findsOneWidget);
    expect(find.text('WTT Champions Chongqing'), findsWidgets);

    // 5. Open Tournaments: Click on "China Smash" in the sidebar
    final chinaSmashFinder = find.widgetWithText(InkWell, 'China Smash');
    expect(chinaSmashFinder, findsOneWidget, reason: 'China Smash tournament should be in sidebar');
    await tester.tap(chinaSmashFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 6. Verify tournament opened and its match ("Lin Shidong vs Ma Long") appears
    final matchCardFinder = find.text('Lin Shidong vs Ma Long').first;
    expect(matchCardFinder, findsWidgets, reason: 'Match from selected tournament should be displayed');

    // 7. Select the match: Tap on "Lin Shidong vs Ma Long" (configured with offsetSeconds = 120)
    await tester.scrollUntilVisible(matchCardFinder, 200.0, scrollable: find.byType(Scrollable).last);
    await tester.pump();
    await tester.tap(matchCardFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 8. Verify native MediaKit video widget mounted
    final videoFinder = find.descendant(of: find.byType(VideoHero), matching: find.byType(Video));
    expect(videoFinder, findsOneWidget, reason: 'Video player should be mounted for selected match');

    final dynamic videoWidget = tester.widget(videoFinder);
    final Player player = videoWidget.controller.player;

    // 9. Verify video seeks to exact start time (120s) and enters active playing state
    bool seekedAndPlaying = false;
    for (int i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (player.state.playing && player.state.position.inSeconds >= 120) {
        seekedAndPlaying = true;
        break;
      }
    }
    expect(
      seekedAndPlaying,
      isTrue,
      reason: 'Video must seek to expected offset (120s) and play! Actual: playing=${player.state.playing}, pos=${player.state.position.inSeconds}s',
    );
    expect(player.state.playing, isTrue, reason: 'Player must be actively playing');
    expect(player.state.duration.inSeconds, equals(300), reason: 'Test video duration should be 300s');

    // 10. Verify F5 refresh shortcut hermetically preserves selected match
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump();

    expect(find.text('Refreshing...'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Refreshing...'), findsNothing);
    expect(filterController.selectedMatch.title, 'Lin Shidong vs Ma Long');
  });
}
