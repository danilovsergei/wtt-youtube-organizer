import 'package:native_surface_view/native_surface_view.dart';
import 'package:native_surface_view/native_surface_view.dart';
import 'package:flutter_app/fullscreen/fullscreen_service.dart';
import 'package:flutter_app/widgets/tv_focusable.dart';
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

  testWidgets('Desktop E2E: opens tournament, selects match, verifies correct start time seeking and playback', (
    WidgetTester tester,
  ) async {
    // 1. Configure hermetic offline services pointing to local assets
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
    final chinaSmashFinder = find.descendant(of: find.byType(Sidebar), matching: find.widgetWithText(TvFocusable, 'China Smash'));
    expect(chinaSmashFinder, findsOneWidget, reason: 'China Smash tournament should be in sidebar');
    await tester.ensureVisible(chinaSmashFinder);
    await tester.tap(chinaSmashFinder);
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 6. Anti-spoiler invariant: All tournament days must be COLLAPSED by default
    expect(
      find.text('Lin Shidong vs Ma Long'),
      findsNothing,
      reason: 'Matches must be collapsed by default to prevent spoilers',
    );
    final dayHeaderFinder = find.descendant(
      of: find.byType(Sidebar),
      matching: find.widgetWithText(TvFocusable, 'Day 7 Finals - Round 2'),
    );
    expect(dayHeaderFinder, findsOneWidget, reason: 'Day 7 Finals header should be visible in collapsed state');

    // 7. Expand Day 7 Finals using TV remote (Select / Enter):
    // Focus Day 7 Finals if not already focused, then trigger expand
    await tester.ensureVisible(dayHeaderFinder);
    await tester.tap(dayHeaderFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify Day 7 Finals expanded and all matches appear (with Lin Shidong vs Ma Long in the middle):
    expect(find.text('Wang Chuqin vs Liang Jingkun'), findsOneWidget);
    expect(find.text('Lin Shidong vs Ma Long'), findsOneWidget);
    expect(find.text('Fan Zhendong vs Xiang Peng'), findsOneWidget);

    // 8. Navigate with remote (D-pad Down) to the match in the middle and select it:
    // Arrow Down 1: Move to first match ("Wang Chuqin vs Liang Jingkun")
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 150));

    // Arrow Down 2: Move to match in the middle ("Lin Shidong vs Ma Long")
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 150));

    // Press Select on remote to play the match in the middle
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 8. Verify native MediaKit video widget mounted
    final videoFinder = find.descendant(of: find.byType(VideoHero), matching: Platform.isAndroid ? find.byType(NativeSurfaceView) : find.byType(Video));
    expect(videoFinder, findsOneWidget, reason: 'Video player should be mounted for selected match');

    final dynamic videoWidget = tester.widget(videoFinder);
    final Player player = videoWidget.controller.player;

    // Verify that Video explicitly uses NoVideoControls so no platform mobile buffering spinners can render
    expect(
      videoWidget.controls,
      equals(NoVideoControls),
      reason: 'Video must use NoVideoControls to prevent media_kit from injecting mobile buffering spinners',
    );

    // 9. Anti-Flicker & Offset Settle Guard:
    // Assert that loading overlay shield remains mounted CONTINUOUSLY while player is buffering/seeking,
    // and is NEVER prematurely dismissed before playback reaches the target match offset (120s).
    bool seekedAndPlaying = false;
    for (int i = 0; i < 55; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      final currentPosSec = player.state.position.inSeconds;
      final overlayPresent = find.byKey(const Key('match_loading_overlay')).evaluate().isNotEmpty;

      // STRICT FLICKER INVARIANT:
      // If position has not reached target offset (120s), loading shield MUST NOT be dismissed!
      if (currentPosSec < 118) {
        expect(
          overlayPresent,
          isTrue,
          reason: 'Flicker regression detected! match_loading_overlay was prematurely dismissed at pos=${currentPosSec}s before reaching target offset (120s)!',
        );
      }

      if (player.state.playing &&
          currentPosSec >= 120 &&
          !overlayPresent) {
        seekedAndPlaying = true;
        break;
      }
    }
    expect(
      seekedAndPlaying,
      isTrue,
      reason: 'Video must seek to expected offset (120s), play, and dismiss overlay! Actual: playing=${player.state.playing}, pos=${player.state.position.inSeconds}s',
    );
    expect(player.state.playing, isTrue, reason: 'Player must be actively playing');
    expect(player.state.duration.inSeconds, equals(300), reason: 'Test video duration should be 300s');

    // Verify loading overlay shield is dismissed ONLY after playback has successfully started
    expect(find.byKey(const Key('match_loading_overlay')), findsNothing, reason: 'Loading overlay must be dismissed once playing');

    // Verify audio volume is unmuted (100%) once playing
    expect(player.state.volume, equals(100.0), reason: 'Player volume must be unmuted (100) after video reveal');

    // Verify active audio track is confirmed attached and playing (sound guard)
    expect(
      player.state.tracks.audio.any((a) => a.id != 'no' && a.id != 'auto'),
      isTrue,
      reason: 'Active audio track must be attached to prevent silent playback. Actual tracks: ${player.state.tracks.audio}',
    );

    // Verify active video track is confirmed attached and playing (video guard)
    expect(
      player.state.tracks.video.any((v) => v.id != 'no' && v.id != 'auto'),
      isTrue,
      reason: 'Active video track must be attached to prevent audio-only / no-video playback. Actual tracks: ${player.state.tracks.video}',
    );
    expect(
      player.state.track.video.id,
      isNot(equals('no')),
      reason: 'Video track must not be dropped to audio-only by decoder',
    );

    // 10. Regression guard: Verify playback speed stability (strictly 1.0x normal speed, NO 2x fast-forward speedup)
    expect(player.state.rate, equals(1.0), reason: 'Player playback rate must be strictly 1.0x');

    final initialPos = player.state.position;
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final elapsedVideoMs = (player.state.position - initialPos).inMilliseconds;
    expect(
      elapsedVideoMs,
      greaterThanOrEqualTo(750),
      reason: 'Video must advance smoothly at normal speed (advanced ${elapsedVideoMs}ms in ~1s)',
    );
    expect(
      elapsedVideoMs,
      lessThanOrEqualTo(1350),
      reason: 'Video must NOT fast-forward at 2x speed (expected ~1000ms per sec, got ${elapsedVideoMs}ms)',
    );

    // 11. TV Remote Playback D-Pad Navigation & Focus Test:
    // Invariant 0: Clean video start - neither play/pause button nor progress bar are displayed
    expect(
      find.byKey(const Key('tv_play_pause_button')),
      findsNothing,
      reason: 'Play/pause button must NOT be displayed when video starts playing',
    );
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: 'Progress bar must NOT be displayed when video starts playing',
    );
    expect(
      find.byKey(const Key('player_diagnostics_badge')),
      findsNothing,
      reason: 'Diagnostics badge must NOT be displayed when video starts playing',
    );

    // A) While video is playing, press Down on remote:
    // Controls must appear and focus must land on the Progress Bar!
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      filterController.progressBarFocusNode.hasFocus,
      isTrue,
      reason: 'Pressing Down during video playback must focus on the progress bar',
    );
    expect(
      find.byType(LinearProgressIndicator),
      findsOneWidget,
      reason: 'Progress bar must become visible when Down is pressed during playback',
    );
    final lpiFocused = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(lpiFocused.minHeight, equals(10.0), reason: 'Progress bar must visually expand to 10px height when focused');

    // Invariant: Progress bar displays match duration (35:00 for test_yt_4) instead of whole stream duration
    expect(
      find.text('35:00'),
      findsOneWidget,
      reason: 'Progress bar must display the match duration (35:00) instead of whole stream duration',
    );
    expect(
      find.byKey(const Key('player_diagnostics_badge')),
      findsOneWidget,
      reason: 'Diagnostics badge must appear in top-right corner when controls wake up',
    );

    // B) Press Up: Focus moves from Progress Bar to Play/Resume button
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.byKey(const Key('tv_play_pause_button')),
      findsOneWidget,
      reason: 'Play/resume button must appear when Up is pressed',
    );
    expect(
      filterController.playButtonFocusNode.hasFocus,
      isTrue,
      reason: 'Pressing Up while on progress bar must move focus to play/resume button',
    );
    expect(
      filterController.progressBarFocusNode.hasFocus,
      isFalse,
      reason: 'Progress bar must lose focus when Up is pressed',
    );

    // C) Press Down: Focus moves back from Play/Resume button to Progress Bar
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      filterController.progressBarFocusNode.hasFocus,
      isTrue,
      reason: 'Pressing Down while on play/resume button must move focus back to progress bar',
    );
    expect(
      filterController.playButtonFocusNode.hasFocus,
      isFalse,
      reason: 'Play/resume button must lose focus when Down is pressed',
    );

    // D) Test Progressive Rewind and Fast-Forward Acceleration on Progress Bar:
    // When Left arrow is pressed repeatedly within 900ms, step accelerates: 10s -> 10s -> 20s -> ...
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(find.text('<< 10s'), findsOneWidget, reason: 'First rewind step must be 10s with badge');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(find.text('<< 20s'), findsOneWidget, reason: 'Second rewind step must be cumulative 20s');

    // Third consecutive press accelerates step to 20s (cumulative 40s)
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(find.text('<< 40s'), findsOneWidget, reason: 'Third accelerated rewind step increases by 20s (cumulative 40s)');

    // Wait for seek debounce timer (300ms) to commit seek
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('<< 40s'), findsNothing, reason: 'Seek badge must dismiss once commit completes');

    // Test Progressive Fast-Forward Acceleration back to ~120s:
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('>> +10s'), findsOneWidget, reason: 'First forward step must be 10s');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('>> +20s'), findsOneWidget, reason: 'Second forward step must be cumulative 20s');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('>> +40s'), findsOneWidget, reason: 'Third accelerated forward step increases by 20s (cumulative 40s)');

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('>> +40s'), findsNothing, reason: 'Seek badge must dismiss once commit completes');

    // E) Hermetic regression test: On pause, verify play/resume button in the middle and bottom progress bar are visible
    await player.pause();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byType(LinearProgressIndicator),
      findsOneWidget,
      reason: 'Progress bar must be visible at the bottom of the video on pause',
    );
    expect(
      find.descendant(of: find.byType(VideoHero), matching: find.byIcon(Icons.play_arrow)),
      findsOneWidget,
      reason: 'Play/resume button must be visible in the middle of the video on pause',
    );

    // Resume video
    await player.play();
    await tester.pump(const Duration(milliseconds: 100));

    // F) Auto-hide test: After 4s of playback, controls auto-hide automatically
    await tester.pump(const Duration(seconds: 4));
    expect(
      find.byKey(const Key('tv_play_pause_button')),
      findsNothing,
      reason: 'Play/pause button must auto-hide after short inactivity during playback',
    );
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: 'Progress bar must auto-hide after short inactivity during playback',
    );
    expect(
      find.byKey(const Key('player_diagnostics_badge')),
      findsNothing,
      reason: 'Diagnostics badge must auto-hide after short inactivity during playback',
    );

    // 12. Verify F5 refresh shortcut hermetically preserves selected match
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump();

    expect(find.text('Refreshing...'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Refreshing...'), findsNothing);
    expect(filterController.selectedMatch.title, 'Lin Shidong vs Ma Long');

    // 14. Android TV Focus Traversal & Fullscreen Back Navigation Test:
    // A) Ensure fullscreen is active:
    if (!isFullscreenNotifier.value) {
      isFullscreenNotifier.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(isFullscreenNotifier.value, isTrue, reason: 'Must be in fullscreen before testing back navigation');

    // B) Press Back / Escape to exit fullscreen:
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    debugPrint('TEST DIAGNOSTIC: isFullscreen=${isFullscreenNotifier.value}, currentMatchFocus=${filterController.currentMatchFocusNode.hasFocus}, playButtonFocus=${filterController.playButtonFocusNode.hasFocus}');
    expect(isFullscreenNotifier.value, isFalse, reason: 'Must exit fullscreen');
    expect(filterController.currentMatchFocusNode.hasFocus, isTrue, reason: 'Focus must be on selected match title in sidebar');
    expect(find.byIcon(Icons.pause), findsOneWidget, reason: 'Play/pause button must be visible on video upon exiting fullscreen');
    expect(filterController.playButtonFocusNode.hasFocus, isFalse, reason: 'Play/pause button must be in UNFOCUSED state');

    // C) Press "Right" arrow: Focus moves from match title to play/pause button
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(filterController.playButtonFocusNode.hasFocus, isTrue, reason: 'Focus must move to play/pause button on video when Right is pressed');
    expect(find.byIcon(Icons.pause), findsOneWidget, reason: 'Play/pause button must remain visible when focused');

    // D) Press "Down" arrow: Focus moves from play/pause button to progress bar
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      filterController.progressBarFocusNode.hasFocus,
      isTrue,
      reason: 'Pressing Down on remote must focus on progress bar',
    );
    expect(
      filterController.playButtonFocusNode.hasFocus,
      isFalse,
      reason: 'Play/pause button must lose focus when Down is pressed',
    );

    // E) Press "Up" arrow: Focus moves back from progress bar to play/pause button
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      filterController.playButtonFocusNode.hasFocus,
      isTrue,
      reason: 'Pressing Up on remote while on progress bar must focus on play/pause button',
    );
    expect(
      filterController.progressBarFocusNode.hasFocus,
      isFalse,
      reason: 'Progress bar must lose focus when Up is pressed',
    );

    // F) Press "Left" arrow: Focus moves back to match title
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(filterController.currentMatchFocusNode.hasFocus, isTrue, reason: 'Focus must return to match title when Left is pressed');
    expect(filterController.playButtonFocusNode.hasFocus, isFalse, reason: 'Play/pause button must lose focus');

    // 13. Rapid Match Switching & Anti-Flicker Guard:
    // Switch match while actively playing at 120s to ensure no FFI callback crash AND no stale clock flicker
    expect(player.state.position.inSeconds, greaterThanOrEqualTo(120), reason: 'Match 1 must be actively playing at or above 120s');

    // Simulate realistic network fetch latency (300ms) for Match 2
    (YtDlpService.instance as TestYtDlpService).responseDelay = const Duration(milliseconds: 300);

    final nextMatch = filterController.allMatches.firstWhere((m) => m.id != filterController.selectedMatch.id);
    final targetOffset2 = nextMatch.offsetSeconds ?? 0; // Starts at 0s

    filterController.selectMatch(nextMatch);
    await tester.pump();

    // Invariant 1: Loading shield must be mounted immediately on Frame 1 of match switch
    expect(
      find.byKey(const Key('match_loading_overlay')),
      findsOneWidget,
      reason: 'Loading overlay must be mounted immediately on frame 1 of match switch to block leftover video frame',
    );

    // Invariant 2: Decoder pipeline must be flushed immediately so player clock resets to 0s
    // Wait for stop event to cross isolate
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (player.state.position.inSeconds < 10) break;
    }
    expect(
      player.state.position.inSeconds,
      lessThan(10),
      reason: 'Stale clock leak: Player clock did not reset to 0s upon match switch, still at ${player.state.position.inSeconds}s!',
    );
    expect(
      find.byKey(const Key('match_loading_overlay')),
      findsOneWidget,
      reason: 'Loading overlay must remain visible while new match is buffering',
    );

    // Verify player widget survives match switch without crashing
    expect(Platform.isAndroid ? find.byType(NativeSurfaceView) : find.byType(Video), findsOneWidget, reason: 'Video player must survive match switch without crashing');
    expect(filterController.selectedMatch.id, equals(nextMatch.id));

    // Invariant 3: Verify overlay is dismissed only when Match 2 is actively decoding at target offset
    bool match2Settled = false;
    for (int i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      final currentPosSec2 = player.state.position.inSeconds;
      final overlayPresent2 = find.byKey(const Key('match_loading_overlay')).evaluate().isNotEmpty;

      if (!overlayPresent2) {
        match2Settled = true;
        break;
      }
    }
    expect(match2Settled, isTrue, reason: 'Match 2 must settle and dismiss loading overlay');

  });
}
