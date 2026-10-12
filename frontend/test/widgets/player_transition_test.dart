import 'package:media_kit_video/media_kit_video.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_app/video/video_player_service.dart';
import 'package:flutter_app/video/ytdlp/ytdlp_service.dart';
import 'package:flutter_app/video/ytdlp/test_ytdlp.dart';
import 'package:media_kit/media_kit.dart';

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

class _DelayedYtDlpService extends TestYtDlpService {
  Completer<void>? completer;

  @override
  Future<VideoStreamMetadata> getVideoStreamMetadata(String youtubeId) async {
    if (completer != null && !completer!.isCompleted) {
      await completer!.future;
    }
    return super.getVideoStreamMetadata(youtubeId);
  }
}

void main() {
  setUpAll(() {
    MediaKit.ensureInitialized();
    HttpOverrides.global = _TestHttpOverrides();
  });

  tearDownAll(() {
    HttpOverrides.global = null;
  });

  group('Video Player Seamless Transition Tests', () {
    testWidgets('Overlay image uses gaplessPlayback to prevent black screen gaps on URL change', (
      WidgetTester tester,
    ) async {
      final delayedService = _DelayedYtDlpService();
      delayedService.completer = Completer<void>();
      YtDlpService.instance = delayedService;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoPlayerWidget.create(
              matchId: 'm1',
              youtubeId: 'yt_1',
              imageUrl: 'https://example.com/thumb1.jpg',
              offsetSeconds: 0,
              onDoubleTap: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      // Find the Image widget rendered inside match_loading_overlay
      final overlayFinder = find.byKey(const Key('match_loading_overlay'));
      expect(overlayFinder, findsOneWidget);

      final imageFinder = find.descendant(
        of: overlayFinder,
        matching: find.byType(Image),
      );
      expect(imageFinder, findsOneWidget);

      final imageWidget = tester.widget<Image>(imageFinder);
      expect(
        imageWidget.gaplessPlayback,
        isTrue,
        reason: 'gaplessPlayback must be true to avoid flashing black while downloading new thumbnails',
      );

      // Clean up completer
      delayedService.completer!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('didUpdateWidget mounts blackout shield immediately on the very first frame of match switch', (
      WidgetTester tester,
    ) async {
      final delayedService = _DelayedYtDlpService();
      YtDlpService.instance = delayedService;

      final mockTournaments = [
        const Tournament(
          id: 't1',
          name: 'WTT Champions',
          year: 2026,
          type: TournamentType.champions,
          location: 'Incheon',
        ),
      ];

      final mockMatches = [
        const Match(
          id: 'm1',
          title: 'Player A vs Player B',
          tournamentId: 't1',
          date: '2026-04-01',
          time: '19:00',
          imageUrl: 'https://example.com/1.jpg',
          tag: 'Singles',
          day: 'Day 1',
          youtubeId: 'yt_1',
          offsetSeconds: 0,
        ),
        const Match(
          id: 'm2',
          title: 'Player C vs Player D',
          tournamentId: 't1',
          date: '2026-04-01',
          time: '20:00',
          imageUrl: 'https://example.com/2.jpg',
          tag: 'Singles',
          day: 'Day 1',
          youtubeId: 'yt_2',
          offsetSeconds: 120,
        ),
      ];

      filterController.setDebugData(mockTournaments, mockMatches);

      // Mount initial screen with Match 1
      await tester.pumpWidget(const WttApp());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Match 1 is loaded, overlay is dismissed
      expect(find.byKey(const Key('match_loading_overlay')), findsNothing);

      // Delay extraction for Match 2 so we can inspect frame 1
      delayedService.completer = Completer<void>();

      // Select Match 2
      filterController.selectMatch(mockMatches[1]);
      await tester.pump(); // Render Frame 1 of Match 2

      // Blackout shield must be mounted on Frame 1 (0ms delay) to prevent seeing unrendered frames
      expect(
        find.byKey(const Key('match_loading_overlay')),
        findsOneWidget,
        reason: 'Blackout shield must be mounted immediately on the first frame of match switch',
      );

      // Complete extraction and let video load
      delayedService.completer!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Overlay dismissed once video is playing
      expect(find.byKey(const Key('match_loading_overlay')), findsNothing);
    });
    testWidgets('TV controls progress bar does not flicker during initial video loading', (
      WidgetTester tester,
    ) async {
      final delayedService = _DelayedYtDlpService();
      delayedService.completer = Completer<void>();
      YtDlpService.instance = delayedService;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoPlayerWidget.create(
              matchId: 'm1',
              youtubeId: 'yt_1',
              imageUrl: 'https://example.com/thumb1.jpg',
              offsetSeconds: 0,
              onDoubleTap: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      // Ensure that TV pause button is not showing while loading
      expect(find.byIcon(Icons.pause), findsNothing);

      delayedService.completer!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    });
    testWidgets('Video widget explicitly uses NoVideoControls to prevent default mobile spinner injection', (
      WidgetTester tester,
    ) async {
      final delayedService = _DelayedYtDlpService();
      YtDlpService.instance = delayedService;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoPlayerWidget.create(
              matchId: 'm1',
              youtubeId: 'yt_1',
              imageUrl: 'https://example.com/thumb1.jpg',
              offsetSeconds: 0,
              onDoubleTap: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      final videoFinder = find.byType(Video);
      expect(videoFinder, findsOneWidget);

      final videoWidget = tester.widget<Video>(videoFinder);
      expect(
        videoWidget.controls,
        equals(NoVideoControls),
        reason: 'Video widget must use NoVideoControls so media_kit does not inject mobile buffering spinners over video',
      );
    });
    testWidgets('VideoPlayerWidget initializes with strictly 1.0x rate', (
      WidgetTester tester,
    ) async {
      final delayedService = _DelayedYtDlpService();
      YtDlpService.instance = delayedService;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoPlayerWidget.create(
              matchId: 'm1',
              youtubeId: 'yt_1',
              imageUrl: 'https://example.com/thumb1.jpg',
              offsetSeconds: 10,
              onDoubleTap: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      final videoFinder = find.byType(Video);
      expect(videoFinder, findsOneWidget);

      final videoWidget = tester.widget<Video>(videoFinder);
      final Player player = videoWidget.controller.player;

      expect(player.state.rate, equals(1.0), reason: 'Playback rate must be initialized to 1.0x');
    });
    testWidgets('VideoPlayerWidget reuses existing VideoController across match updates to prevent FFI callback deletion crash', (
      WidgetTester tester,
    ) async {
      final delayedService = _DelayedYtDlpService();
      YtDlpService.instance = delayedService;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoPlayerWidget.create(
              key: const Key('main_video_player'),
              matchId: 'm1',
              youtubeId: 'yt_1',
              imageUrl: 'https://example.com/thumb1.jpg',
              offsetSeconds: 0,
              onDoubleTap: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      final videoFinder = find.byType(Video);
      expect(videoFinder, findsOneWidget);
      final initialController = tester.widget<Video>(videoFinder).controller;

      // Update widget to match 2 with same key (simulating main.dart match selection)
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoPlayerWidget.create(
              key: const Key('main_video_player'),
              matchId: 'm2',
              youtubeId: 'yt_2',
              imageUrl: 'https://example.com/thumb2.jpg',
              offsetSeconds: 60,
              onDoubleTap: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      final updatedController = tester.widget<Video>(videoFinder).controller;

      // Assert that controller and native FFI callbacks are preserved (NOT recreated/disposed)
      expect(
        identical(initialController, updatedController),
        isTrue,
        reason: 'Controller must be preserved across match changes to prevent native FFI callback deletion crashes',
      );
    });
    testWidgets('Video widget is pre-mounted at startup with safe VO to avoid dynamic surface race crash', (
      WidgetTester tester,
    ) async {
      final delayedService = _DelayedYtDlpService();
      YtDlpService.instance = delayedService;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoPlayerWidget.create(
              key: const Key('main_video_player'),
              matchId: 'm1',
              youtubeId: 'yt_1',
              imageUrl: 'https://example.com/thumb1.jpg',
              offsetSeconds: 0,
              onDoubleTap: () {},
              autoPlay: false, // Matches initial app boot state before user picks a match
            ),
          ),
        ),
      );
      await tester.pump();

      // Guard 1: Video widget MUST be mounted from startup so native Android Surface is warm
      expect(
        find.byType(Video),
        findsOneWidget,
        reason: 'Video widget must be mounted from startup so native Android Surface is warm and does not trigger dynamic mount race crashes',
      );




    });
  });
}
