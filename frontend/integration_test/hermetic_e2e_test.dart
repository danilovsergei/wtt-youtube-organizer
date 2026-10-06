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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();
  });

  testWidgets('Fully hermetic desktop E2E: boots app, selects match, verifies start offset seeking and playback', (
    WidgetTester tester,
  ) async {
    // 1. Configure hermetic offline services pointing to local assets
    DatabaseService.instance = LocalDatabaseService(
      localJsonPath: 'test/assets/mock_schedule.json',
    );
    YtDlpService.instance = TestYtDlpService(
      localVideoPath: 'test/assets/test_video.mp4',
      mockResolutions: [1080, 720, 480],
    );

    // 2. Initialize local database and pre-load schedule
    await DatabaseService.instance.initialize();
    await filterController.fetchData();

    // 3. Launch full desktop app
    await tester.pumpWidget(const WttApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 4. Verify Tournaments & Matches loaded into UI
    expect(find.text('Tournaments'), findsOneWidget);
    expect(find.text('WTT Champions Chongqing'), findsWidgets);
    expect(find.text('Wang Chuqin vs Fan Zhendong'), findsWidgets);

    // 5. Select a specific match from the list: "Sun Yingsha vs Wang Manyu" (configured with offsetSeconds = 15)
    final matchCardFinder = find.text('Sun Yingsha vs Wang Manyu').first;
    // Scroll the main content to bring the match card into view
    await tester.scrollUntilVisible(matchCardFinder, 200.0, scrollable: find.byType(Scrollable).last);
    await tester.pump();
    
    await tester.tap(matchCardFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 6. Verify native MediaKit video widget mounted and inspected
    final videoFinder = find.descendant(of: find.byType(VideoHero), matching: find.byType(Video));
    expect(videoFinder, findsOneWidget, reason: 'Video widget should be mounted for selected match');

    final dynamic videoWidget = tester.widget(videoFinder);
    final Player player = videoWidget.controller.player;

    // 7. Verify video seeks to expected start offset (15s) and starts playing
    bool seekedAndPlaying = false;
    for (int i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (player.state.playing && player.state.position.inSeconds >= 15) {
        seekedAndPlaying = true;
        break;
      }
    }
    expect(
      seekedAndPlaying,
      isTrue,
      reason: 'Video must seek to expected offset (15s) and enter playing state! Actual: playing=${player.state.playing}, pos=${player.state.position.inSeconds}s',
    );

    // 8. Verify playback is actively playing
    expect(player.state.playing, isTrue, reason: 'Player should remain in playing state');
    expect(player.state.duration.inSeconds, equals(300), reason: 'Test video duration should be 300s');

    // 9. Verify F5 refresh shortcut hermetically preserves selected match
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump();

    expect(find.text('Refreshing...'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Refreshing...'), findsNothing);
    expect(filterController.selectedMatch.title, 'Sun Yingsha vs Wang Manyu');
  });
}
