import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/main.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_app/video/ytdlp/ytdlp_service.dart';
import 'package:flutter_app/video/ytdlp/test_ytdlp.dart';
import 'package:flutter_app/data/database_service.dart';
import 'package:flutter_app/data/local_database.dart';

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

  final mockData = [
    {
      'tournament': 'WTT Champions Montpellier',
      'year': 2026,
      'location': 'Montpellier, France',
      'team_a': 'Felix Lebrun',
      'team_b': 'Anders Lind',
      'upload_date': '2026-10-28T10:00:00Z',
      'youtube_id': 'yt_mont_1',
      'is_doubles': false,
      'day': 'Day 2',
      'match_time': '19:00',
    },
    {
      'tournament': 'WTT Champions Montpellier',
      'year': 2026,
      'location': 'Montpellier, France',
      'team_a': 'Felix Lebrun',
      'team_b': 'Truls Moregard',
      'upload_date': '2026-10-28T11:00:00Z',
      'youtube_id': 'yt_mont_2',
      'is_doubles': false,
      'day': 'Day 1',
      'match_time': '20:00',
    },
    {
      'tournament': 'China Smash',
      'year': 2026,
      'location': 'Beijing, China',
      'team_a': 'Ma Long',
      'team_b': 'Lin Shidong',
      'upload_date': '2026-10-01T10:00:00Z',
      'youtube_id': 'yt_china_1',
      'is_doubles': false,
      'day': 'Day 1',
      'match_time': '19:00',
    },
  ];

  setUp(() {
    DatabaseService.instance = LocalDatabaseService(initialData: mockData);
    filterController.reset();
  });

  testWidgets('Search UI: typing into search field filters tournaments and matches in real time', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const WttApp());
    await filterController.fetchData();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 1. Initially both tournaments are displayed in the sidebar
    expect(find.text('WTT Champions Montpellier'), findsOneWidget);
    expect(find.text('China Smash'), findsOneWidget);

    // 2. Type "Lebrun" in the search TextField
    final searchInputFinder = find.byType(TextField);
    expect(searchInputFinder, findsOneWidget);

    await tester.enterText(searchInputFinder, 'Lebrun');
    await tester.pump(const Duration(milliseconds: 300));

    // Only Montpellier is displayed (Lebrun played there), China Smash is filtered out
    expect(find.text('WTT Champions Montpellier'), findsOneWidget);
    expect(find.text('China Smash'), findsNothing);

    // Multiple matches for Lebrun, so tournament list stays unexpanded
    expect(filterController.selectedTournamentId, isEmpty);

    // 3. Tap Montpellier to inspect days
    await tester.tap(find.text('WTT Champions Montpellier'));
    await tester.pump(const Duration(milliseconds: 300));

    // Days are displayed collapsed
    expect(find.text('Day 1'), findsOneWidget);
    expect(find.text('Day 2'), findsOneWidget);

    // 4. Type specific matchup "Lebrun Lind" -> isolates single match across app
    await tester.enterText(searchInputFinder, 'Lebrun Lind');
    await tester.pump(const Duration(milliseconds: 300));

    // Automatically navigates to tournament and reveals the single match!
    expect(find.text('Felix Lebrun vs Anders Lind'), findsWidgets);

    // 5. Clear search input via clear icon
    final clearButton = find.byIcon(Icons.clear);
    expect(clearButton, findsOneWidget);

    await tester.tap(clearButton);
    await tester.pump(const Duration(milliseconds: 300));

    // Search query is cleared and tournaments restored
    expect(filterController.searchQuery, isEmpty);
  });
}
