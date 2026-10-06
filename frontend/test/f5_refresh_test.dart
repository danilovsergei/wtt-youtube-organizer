import "dart:async";
import "dart:io";
import "dart:typed_data";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:flutter_app/main.dart";
import "package:media_kit/media_kit.dart";
import "package:flutter_app/video/ytdlp/ytdlp_service.dart";
import "package:flutter_app/video/ytdlp/test_ytdlp.dart";

// 1x1 transparent PNG bytes for mock Image responses
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
  setUpAll(() {
    YtDlpService.instance = TestYtDlpService();
    HttpOverrides.global = _TestHttpOverrides();
    MediaKit.ensureInitialized();
  });

  setUp(() {
    filterController.customDataFetcher = null;
  });

  testWidgets("F5 shortcut triggers Refreshing dialog, calls fetchData, and updates data", (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    // Initial mock data
    filterController.setDebugData(
      [
        const Tournament(
          id: "t1_2026",
          name: "Initial Tournament",
          year: 2026,
          type: TournamentType.contender,
          location: "Location A",
        ),
      ],
      [
        const Match(
          id: "m1",
          title: "Initial Match",
          tournamentId: "t1_2026",
          date: "2026-01-15",
          time: "20:00",
          imageUrl: "https://example.com/thumb.jpg",
          tag: "Singles",
          day: "Day 1",
        ),
      ],
    );

    int fetchCalls = 0;
    filterController.customDataFetcher = () async {
      fetchCalls++;
      // Return updated tournament schedule from server
      return [
        {
          "tournament": "Refreshed WTT Champions",
          "year": 2026,
          "video_title": "Refreshed Final Match",
          "upload_date": "2026-10-05T15:00:00Z",
          "youtube_id": "test_yt_id",
          "is_doubles": false,
          "day": "Day 2",
        },
      ];
    };

    await tester.pumpWidget(const WttApp());
    await tester.pump();

    // Verify initial tournament rendered
    expect(find.text("Tournaments"), findsOneWidget);
    expect(find.text("Initial Tournament"), findsWidgets);

    // Press F5 key
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump(); // Show dialog frame

    // Verify "Refreshing..." popup dialog is visible
    expect(find.text("Refreshing..."), findsOneWidget);

    // Settle dialog and async fetchData completion
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    // Verify dialog dismissed
    expect(find.text("Refreshing..."), findsNothing);

    // Verify fetchData was called
    expect(fetchCalls, 1);

    // Verify newly refreshed tournament and match are present in FilterController
    expect(filterController.allTournaments.any((t) => t.name == "Refreshed WTT Champions"), isTrue);
    expect(filterController.allMatches.any((m) => m.title == "Refreshed Final Match"), isTrue);
  });
}
