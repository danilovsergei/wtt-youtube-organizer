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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    MediaKit.ensureInitialized();
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

    // 4. Open Tournaments on mobile: Tap the Menu/Drawer button in MobileHeader
    final menuButtonFinder = find.byIcon(Icons.menu);
    expect(menuButtonFinder, findsOneWidget, reason: 'Menu drawer button should be visible on mobile');
    await tester.tap(menuButtonFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 5. Select tournament: Tap on "China Smash" inside the drawer
    final chinaSmashFinder = find.widgetWithText(InkWell, 'China Smash');
    expect(chinaSmashFinder, findsOneWidget, reason: 'China Smash tournament should be in drawer');
    await tester.tap(chinaSmashFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 6. Close the drawer to view the tournament matches
    final drawerFinder = find.byType(Drawer);
    if (drawerFinder.evaluate().isNotEmpty) {
      Navigator.of(tester.element(drawerFinder.first)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    // 7. Select match: Tap on "Lin Shidong vs Ma Long" (configured with offsetSeconds = 120)
    final matchCardFinder = find.text('Lin Shidong vs Ma Long').first;
    expect(matchCardFinder, findsWidgets, reason: 'Match from China Smash should be displayed');

    await tester.scrollUntilVisible(
      matchCardFinder,
      200.0,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pump(const Duration(milliseconds: 200));

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
