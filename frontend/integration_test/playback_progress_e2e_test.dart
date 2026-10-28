import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
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
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
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
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      await windowManager.ensureInitialized();
    }
  });

  testWidgets('E2E: saves match playback progress locally and resumes from saved position when reopened', (
    WidgetTester tester,
  ) async {
    // 1. Configure hermetic offline database and local yt-dlp test double
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

    // 2. Launch App
    await tester.pumpWidget(const WttApp());
    await tester.pumpAndSettle();

    // 3. Select tournament and load matches
    final tournament = filterController.allTournaments.firstWhere((t) => t.name == 'China Smash');
    await filterController.selectTournament(tournament.id);
    await tester.pumpAndSettle();

    // 4. Select Match 0 (Lin Shidong vs Ma Long, default offset is 120s)
    final match0 = filterController.allMatches.firstWhere((m) => m.title.contains('Lin Shidong'));
    debugPrint('DIAGNOSTICS: match0.id=${match0.id}, title=${match0.title}');
    expect(match0.offsetSeconds, 120, reason: 'Initial match offset should be 120s');
    filterController.selectMatch(match0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();

    // Find the mounted Player instance
    final videoFinder = find.descendant(
      of: find.byType(VideoHero),
      matching: Platform.isAndroid ? find.byType(NativeSurfaceView) : find.byType(Video),
    );
    expect(videoFinder, findsOneWidget, reason: 'Video player should be mounted');
    final dynamic videoWidget = tester.widget(videoFinder);
    final Player player = videoWidget.controller.player;

    // Wait until playing at default offset
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (player.state.playing && player.state.position.inSeconds >= 118) break;
    }

    // 5. Seek forward to 180s (representing 60s of watched progress into the match)
    await player.seek(const Duration(seconds: 180));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // Pause to trigger progress persistence
    await player.pause();
    await tester.pump(const Duration(milliseconds: 500));

    // 6. Select Match 1 to switch away
    final match1 = filterController.allMatches.firstWhere((m) => m.title.contains('Wang Chuqin'));
    filterController.selectMatch(match1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();

    // 7. Re-open Match 0!
    filterController.selectMatch(match0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();

    // 8. Assert that playback resumed at the saved position (>=170s) rather than initial offset (120s)!
    final currentPos = player.state.position.inSeconds;
    expect(
      currentPos,
      greaterThanOrEqualTo(170),
      reason: 'Reopened match must resume from saved watch position (~180s), not initial offset (120s)! Actual: ${currentPos}s',
    );

    // Exit fullscreen so the matches navigator sidebar is visible
    isFullscreenNotifier.value = false;
    await tester.pumpAndSettle();

    // 9. Assert that match progress indicator is visible in the matches navigator
    expect(
      find.byKey(Key('match_progress_bar_${match0.id}')),
      findsOneWidget,
      reason: 'Match progress bar must be visible in the matches navigator for in-progress match',
    );
    expect(
      find.byKey(Key('match_progress_badge_${match0.id}')),
      findsOneWidget,
      reason: 'Match progress percentage badge must be visible in the matches navigator for in-progress match',
    );
  });

  testWidgets('E2E: shows progress indicator in matches navigator on cold start without playing first', (
    WidgetTester tester,
  ) async {
    // 1. Simulate existing progress saved from a previous session on disk
    final tempDir = Directory.systemTemp.createTempSync('progress_cold_start_');
    final tempFile = File('${tempDir.path}/test_progress.json');
    PlaybackProgressService.instance.resetForTesting();
    PlaybackProgressService.instance.customStoragePath = tempFile.path;

    // Save progress for test_yt_4 at offset 120 (50% watched: 120 offset + 1050 watched = 1170s)
    await PlaybackProgressService.instance.saveProgress(
      matchId: 'test_yt_4_120',
      positionSeconds: 1170,
      defaultOffsetSeconds: 120,
      matchDurationSeconds: 2100,
      youtubeId: 'test_yt_4',
    );

    // Reset memory cache to simulate fresh cold boot
    PlaybackProgressService.instance.resetForTesting();
    PlaybackProgressService.instance.customStoragePath = tempFile.path;

    // 2. Configure hermetic offline database and eager load progress as main() does on cold boot
    DatabaseService.instance = LocalDatabaseService(
      localJsonPath: 'test/assets/mock_schedule.json',
    );
    await DatabaseService.instance.initialize();
    await PlaybackProgressService.instance.loadProgress();
    await filterController.fetchData();

    // 3. Launch App fresh
    await tester.pumpWidget(const WttApp());
    await tester.pumpAndSettle();

    // 4. Select tournament 'China Smash' if not already selected
    final tournament = filterController.allTournaments.firstWhere((t) => t.name == 'China Smash');
    if (filterController.selectedTournamentId != tournament.id) {
      await filterController.selectTournament(tournament.id);
      await tester.pumpAndSettle();
    }

    // 5. Expand the Day node containing Lin Shidong vs Ma Long if collapsed
    final match = filterController.allMatches.firstWhere((m) => m.title.contains('Lin Shidong'));
    final groupKey = match.session != null ? '${match.day} - Round ${match.session}' : match.day;
    if (!filterController.isDayExpanded(match.tournamentId, groupKey)) {
      filterController.toggleDay(match.tournamentId, groupKey);
      await tester.pumpAndSettle();
    }

    // 6. Assert that progress indicator is immediately visible WITHOUT playing video!
    expect(
      find.byKey(Key('match_progress_bar_${match.id}')),
      findsOneWidget,
      reason: 'Progress bar must be visible immediately on cold start when Day is opened',
    );
    expect(
      find.byKey(Key('match_progress_badge_${match.id}')),
      findsOneWidget,
      reason: 'Progress badge (50%) must be visible immediately on cold start when Day is opened',
    );

    tempDir.deleteSync(recursive: true);
  });
}
