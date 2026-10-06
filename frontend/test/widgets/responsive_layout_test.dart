import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/main.dart';
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

void main() {
  setUpAll(() {
    HttpOverrides.global = _TestHttpOverrides();
    MediaKit.ensureInitialized();
  });

  final mockTournaments = [
    const Tournament(
      id: 't1',
      name: 'WTT Champions Incheon 2026',
      year: 2026,
      type: TournamentType.champions,
      location: 'Incheon, South Korea',
    ),
  ];

  final mockMatches = [
    const Match(
      id: 'm1',
      title: 'Lin Yun-Ju vs Ma Long',
      tournamentId: 't1',
      date: '2026-04-01',
      time: '19:00',
      imageUrl: 'https://example.com/thumb.jpg',
      tag: 'Singles',
      day: 'Day 1',
    ),
  ];

  setUp(() {
    filterController.setDebugData(mockTournaments, mockMatches);
  });

  group('Multi-Platform Responsive Viewport Tests', () {
    testWidgets('Mobile Android Viewport (392x850): shows drawer button and no overflow', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(392, 850);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(const WttApp());
      await tester.pump();

      // Verify no overflow exception occurred
      final err = tester.takeException(); if (err != null) { for (final d in (err as FlutterError).diagnostics) { print(d.toStringDeep()); } } expect(err, isNull);

      // On mobile (<768), MobileHeader is visible
      expect(find.byType(MobileHeader), findsOneWidget);

      // Desktop sidebar should NOT be visible in main row
      expect(
        find.descendant(of: find.byType(Row), matching: find.byType(Sidebar)),
        findsNothing,
      );

      // Open the Drawer
      final scaffoldState = tester.state<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      // Drawer is now open with Sidebar inside
      expect(find.byType(Drawer), findsOneWidget);
      expect(find.text('WTT Champions Incheon 2026'), findsWidgets);
    });

    testWidgets('Desktop Viewport (1920x1080): shows sidebar side-by-side with resize handle', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(const WttApp());
      await tester.pump();

      // Verify no overflow exception occurred
      final err = tester.takeException(); if (err != null) { for (final d in (err as FlutterError).diagnostics) { print(d.toStringDeep()); } } expect(err, isNull);

      // MobileHeader should NOT be visible on desktop
      expect(find.byType(MobileHeader), findsNothing);

      // Sidebar should be directly mounted in the row
      expect(
        find.descendant(of: find.byType(Row), matching: find.byType(Sidebar)),
        findsOneWidget,
      );

      // MouseRegion for resize column should exist
      expect(
        find.byWidgetPredicate((w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn),
        findsOneWidget,
      );
    });

    testWidgets('Tablet Viewport (800x1280): activates desktop layout without overflow', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(const WttApp());
      await tester.pump();

      final err = tester.takeException(); if (err != null) { for (final d in (err as FlutterError).diagnostics) { print(d.toStringDeep()); } } expect(err, isNull);
      // 800 >= 768 -> desktop side-by-side layout
      expect(
        find.descendant(of: find.byType(Row), matching: find.byType(Sidebar)),
        findsOneWidget,
      );
    });
  });
}
