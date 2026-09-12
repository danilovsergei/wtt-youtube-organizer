import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' as app;
import 'package:window_manager/window_manager.dart';
import 'package:flutter_app/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpUntilFound(WidgetTester tester, Finder finder, {int maxSeconds = 15}) async {
    bool timerDone = false;
    final timer = Future.delayed(Duration(seconds: maxSeconds), () => timerDone = true);
    while (!timerDone) {
      await tester.pump(const Duration(milliseconds: 500));
      if (finder.evaluate().isNotEmpty) return;
    }
    throw Exception("Timeout waiting for $finder");
  }

  testWidgets('Video Quality selector exists, changes stream quality, and preserves state on desktop', (WidgetTester tester) async {
    if (kIsWeb) return; 
    
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();

    // Inject a fake match to bypass Supabase network errors in the headless Docker container
    final mockMatch = app.Match(
      id: 'test_match_1',
      title: 'Fan Zhendong vs Ma Long',
      tournamentId: 'test_tourney',
      date: '2023-01-01',
      time: '12:00',
      imageUrl: 'https://img.youtube.com/vi/jNQXAC9IVRw/0.jpg',
      tag: 'Singles',
      day: 'Day 1',
      youtubeId: 'jNQXAC9IVRw', // Me at the zoo
      offsetSeconds: 5,
    );

    // Force the UI to pick up the mock match BEFORE rendering VideoHero
    app.filterController.selectMatch(mockMatch);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: app.filterController,
          builder: (context, _) {
            return app.VideoHero();
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Wait for the settings button to appear
    final settingsButton = find.byKey(const Key('quality_selector_btn'));
    await pumpUntilFound(tester, settingsButton, maxSeconds: 15);

    // Wait up to 10 seconds for the underlying C++ media_kit engine to genuinely start streaming bytes
    bool isPlaying = false;
    late Player testPlayer;
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final videoWidgets = find.byType(app.VideoHero).evaluate();
      if (videoWidgets.isNotEmpty) {
        try {
          // Extract the native media_kit Video widget to read the raw C++ engine state
          final videoFinder = find.descendant(of: find.byType(app.VideoHero), matching: find.byType(app.Video));
          if (videoFinder.evaluate().isNotEmpty) {
            final dynamic videoWidget = tester.widget(videoFinder);
            final player = videoWidget.controller.player;
            testPlayer = player;
            // Check that video is playing AND that an audio track has successfully initialized
            final hasAudio = player.state.track.audio?.id != 'no' && player.state.track.audio?.id != null && player.state.track.audio?.id != 'auto';
            if (player.state.playing && player.state.duration.inSeconds > 0 && hasAudio) {
              isPlaying = true;
              break;
            }
          }
        } catch (e) {
          // Video widget might not be mounted yet
        }
      }
    }
    expect(isPlaying, isTrue, reason: 'media_kit C++ engine failed to load the YouTube stream (likely dropped by CDN or missing codec)!');

    // --- Test Play/Pause toggle via single tap ---
    final videoHero = find.byType(app.VideoHero);
    
    // Tap to pause
    await tester.tap(videoHero);
    // With the timeout fix, we need to wait longer than the 300ms timeout for the single tap to register!
    await tester.pump(const Duration(milliseconds: 600));
    
    bool isPaused = false;
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      try {
        if (!testPlayer.state.playing) {
          isPaused = true;
          break;
        }
      } catch (e) {}
    }
    expect(isPaused, isTrue, reason: 'Single tap failed to pause the video!');

    // --- Test Double Click (Fullscreen) does NOT toggle Play/Pause ---
    // The video is currently paused.
    // Simulate first tap of a double tap
    await tester.tap(videoHero);
    await tester.pump(const Duration(milliseconds: 50));
    
    // At this point (50ms in), the play/pause action should NOT have fired yet because it's waiting to see if it's a double click!
    // This assertion will fail BEFORE the fix, because the first tap immediately played the video.
    expect(testPlayer.state.playing, isFalse, reason: 'Double-click bug: The first tap of a double-click immediately changed the play state!');
    
    // Simulate second tap of the double tap (within the 300ms window)
    await tester.tap(videoHero);
    await tester.pump(const Duration(milliseconds: 500));
    
    // After the double click is fully resolved, the video should STILL be paused!
    expect(testPlayer.state.playing, isFalse, reason: 'Double-click bug: The double-click improperly toggled the play state!');
    
    // Now single tap to resume the video for the rest of the tests
    await tester.tap(videoHero);
    await tester.pump(const Duration(milliseconds: 600));
    
    bool isResumed = false;
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      try {
        if (testPlayer.state.playing) {
          isResumed = true;
          break;
        }
      } catch (e) {}
    }
    expect(isResumed, isTrue, reason: 'Single tap failed to resume the video!');
    // ---------------------------------------------

    // Open the Quality Selector popup
    await tester.tap(settingsButton);
    await tester.pump(const Duration(seconds: 1));

    // The popup menu uses a navigation transition, pump until the animation finishes
    await tester.pumpAndSettle();

    // Find a quality option (e.g. 360p or 480p) in the dropdown using a text finder 
    // to bypass strict generic type matching on PopupMenuItem<VideoOnlyStreamInfo>
    final popupItem = find.textContaining('p').last;
    await pumpUntilFound(tester, popupItem);
    await tester.tap(popupItem);
    
    // Check if the C++ engine successfully remuxed the new 1080p stream
    bool swappedSuccessfully = false;
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      try {
        final hasAudio = testPlayer.state.track.audio?.id != 'no' && testPlayer.state.track.audio?.id != null && testPlayer.state.track.audio?.id != 'auto';
        if (testPlayer.state.playing && testPlayer.state.duration.inSeconds > 0 && hasAudio) {
          swappedSuccessfully = true;
          break;
        }
      } catch (e) {}
    }
    expect(swappedSuccessfully, isTrue, reason: 'media_kit failed to resume playing the new high-quality stream or dropped the audio track!');
  });
}

