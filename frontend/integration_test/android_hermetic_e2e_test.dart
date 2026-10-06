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

  testWidgets('Android Fully Hermetic E2E: boots offline, selects match, plays local video on Pixel 9 Pro XL', (WidgetTester tester) async {
    // 1. Configure 100% hermetic offline services for Android
    DatabaseService.instance = LocalDatabaseService();
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

    // 4. Verify Local Tournaments and Matches rendered in UI
    expect(find.text('WTT Champions Chongqing'), findsWidgets);
    expect(find.text('Wang Chuqin vs Fan Zhendong'), findsWidgets);

    // 5. Verify Video widget mounted
    final videoFinder = find.descendant(of: find.byType(VideoHero), matching: find.byType(Video));
    expect(videoFinder, findsOneWidget);

    final dynamic videoWidget = tester.widget(videoFinder);
    final Player player = videoWidget.controller.player;

    // 6. Verify local test video playback started on Android
    bool isPlaying = false;
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      debugPrint('[$i] Hermetic Android Player: playing=${player.state.playing}, dur=${player.state.duration.inSeconds}s, pos=${player.state.position.inSeconds}s');
      if (player.state.playing || player.state.duration.inSeconds > 0) {
        isPlaying = true;
        break;
      }
    }

    expect(
      isPlaying,
      isTrue,
      reason: 'Local video should play hermetically on Android Pixel 9 Pro XL',
    );
    expect(player.state.duration.inSeconds, equals(300));

    // 7. Select second match: "Sun Yingsha vs Wang Manyu"
    final secondMatchFinder = find.text('Sun Yingsha vs Wang Manyu').first;
    // Bring into view
    await tester.scrollUntilVisible(
      secondMatchFinder,
      200.0,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pump();
    await tester.tap(secondMatchFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Verify player is playing second match
    expect(filterController.selectedMatch.title, 'Sun Yingsha vs Wang Manyu');
    expect(player.state.playing, isTrue);
  });
}
