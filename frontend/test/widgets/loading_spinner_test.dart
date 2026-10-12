import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/main.dart';
import 'package:media_kit/media_kit.dart';
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

class _DelayedYtDlpService extends TestYtDlpService {
  final Completer<void> extractionCompleter = Completer<void>();

  @override
  Future<VideoStreamMetadata> getVideoStreamMetadata(String youtubeId) async {
    // Wait until test unblocks the extraction
    await extractionCompleter.future;
    return super.getVideoStreamMetadata(youtubeId);
  }
}

void main() {
  setUpAll(() {
    HttpOverrides.global = _TestHttpOverrides();
    MediaKit.ensureInitialized();
  });

  testWidgets('Immediate loading spinner is shown the moment a match is selected while yt-dlp resolves', (
    WidgetTester tester,
  ) async {
    final delayedService = _DelayedYtDlpService();
    YtDlpService.instance = delayedService;

    final mockTournaments = [
      const Tournament(
        id: 't1',
        name: 'WTT Incheon 2026',
        year: 2026,
        type: TournamentType.champions,
        location: 'Incheon',
      ),
    ];

    final mockMatches = [
      const Match(
        id: 'm1',
        title: 'Match One',
        tournamentId: 't1',
        date: '2026-04-01',
        time: '19:00',
        imageUrl: 'https://example.com/1.jpg',
        tag: 'Singles',
        day: 'Day 1',
        youtubeId: 'yt_1',
      ),
      const Match(
        id: 'm2',
        title: 'Match Two',
        tournamentId: 't1',
        date: '2026-04-01',
        time: '20:00',
        imageUrl: 'https://example.com/2.jpg',
        tag: 'Singles',
        day: 'Day 1',
        youtubeId: 'yt_2',
      ),
    ];

    filterController.setDebugData(mockTournaments, mockMatches);

    // Initial mount - m1 is selected, but not auto-played
    await tester.pumpWidget(const WttApp());
    await tester.pump();

    // Select match m1 to start loading
    filterController.selectMatch(mockMatches.first);
    await tester.pump();

    // Verify loading overlay with spinner is displayed immediately on the video area!
    final overlayFinder = find.byKey(const Key('match_loading_overlay'));
    expect(overlayFinder, findsOneWidget, reason: 'Loading overlay must appear immediately while yt-dlp resolves');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Complete extraction
    delayedService.extractionCompleter.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Overlay is completely dismissed once video starts
    expect(overlayFinder, findsNothing, reason: 'Overlay should be dismissed once video is ready');
  });
}
