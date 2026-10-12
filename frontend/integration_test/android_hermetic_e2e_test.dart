import 'package:flutter_app/widgets/tv_focusable.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
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
    MediaKit.ensureInitialized();
    HttpOverrides.global = _TestHttpOverrides();
  });

  testWidgets('Android E2E: opens tournament, selects match, verifies correct start time seeking and playback', (WidgetTester tester) async {
    // 1. Configure 100% hermetic offline services for Android
    DatabaseService.instance = LocalDatabaseService();
    // Register China Smash match with offset 120s
    final localDb = LocalDatabaseService();
    localDb.setScheduleData([
      {
        'tournament': 'WTT Champions Chongqing',
        'year': 2026,
        'team_a': 'Wang Chuqin',
        'team_b': 'Fan Zhendong',
        'upload_date': '2026-06-01T15:00:00Z',
        'youtube_id': 'test_yt_hero',
        'is_doubles': false,
        'day': 'Day 4 Finals',
        'session': 2,
        'video_offset_seconds': 0,
        'match_time': '19:00',
      },
      {
        'tournament': 'China Smash',
        'year': 2025,
        'team_a': 'Lin Shidong',
        'team_b': 'Ma Long',
        'upload_date': '2025-10-06T12:00:00Z',
        'youtube_id': 'test_yt_4',
        'is_doubles': false,
        'day': 'Day 7 Finals',
        'session': 2,
        'video_offset_seconds': 120,
        'match_time': '18:00',
      },
    ]);
    DatabaseService.instance = localDb;

    YtDlpService.instance = TestYtDlpService(
      localVideoPath: '/data/local/tmp/test_video.mp4',
      mockResolutions: [1080, 720, 480],
    );

    // 2. Pre-load local schedule
    await DatabaseService.instance.initialize();
    await filterController.fetchData();

    // 3. Launch App on Android
    await tester.pumpWidget(const WttApp());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // 4. Open Tournaments (on mobile phone via drawer menu button, or directly on Android TV sidebar)
    final menuButtonFinder = find.byIcon(Icons.menu);
    if (menuButtonFinder.evaluate().isNotEmpty) {
      await tester.tap(menuButtonFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    // 5. Select tournament: Scroll until visible and tap on "China Smash"
    final chinaSmashFinder = find.descendant(of: find.byType(Sidebar), matching: find.widgetWithText(TvFocusable, 'China Smash'));
    expect(chinaSmashFinder, findsOneWidget, reason: 'China Smash tournament should be found');
    final sidebarScrollable = find.descendant(
      of: find.byType(Sidebar),
      matching: find.byType(Scrollable),
    );
    if (sidebarScrollable.evaluate().isNotEmpty) {
      await tester.scrollUntilVisible(chinaSmashFinder, 50.0, scrollable: sidebarScrollable.first);
    }
    await tester.tap(chinaSmashFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 6. Select match from China Smash in the sidebar / drawer tree view
    final matchCardFinder = find.descendant(
      of: find.byType(Sidebar),
      matching: find.text('Lin Shidong vs Ma Long'),
    ).first;
    expect(matchCardFinder, findsWidgets, reason: 'Match from China Smash should be displayed in sidebar');

    debugPrint('Before tap: selectedMatch=${filterController.selectedMatch.title}');
    await tester.tap(matchCardFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    debugPrint('After tap: selectedMatch=${filterController.selectedMatch.title}');

    // 8. Verify Video widget mounted
    final videoFinder = find.descendant(of: find.byType(VideoHero), matching: find.byType(Video));
    expect(videoFinder, findsOneWidget, reason: 'Video player should be mounted for selected match');

    final dynamic videoWidget = tester.widget(videoFinder);
    final Player player = videoWidget.controller.player;

    // 9. Verify video seeks to exact start time (120s) and enters active playing state on Android
    bool seekedAndPlaying = false;
    for (int i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      debugPrint('[$i] Android Player: playing=${player.state.playing}, dur=${player.state.duration.inSeconds}s, pos=${player.state.position.inSeconds}s');
      if (player.state.playing && player.state.position.inSeconds >= 120) {
        seekedAndPlaying = true;
        break;
      }
    }

    expect(
      seekedAndPlaying,
      isTrue,
      reason: 'Video should seek to expected offset (120s) and enter playing state! Actual: playing=${player.state.playing}, pos=${player.state.position.inSeconds}s',
    );
    expect(player.state.playing, isTrue, reason: 'Player should be in playing state');
    expect(player.state.duration.inSeconds, equals(300), reason: 'Duration of test video should be 300s');
    expect(filterController.selectedMatch.title, 'Lin Shidong vs Ma Long');
  });
}