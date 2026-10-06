import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_app/data/database_service.dart';
import 'package:flutter_app/data/local_database.dart';
import 'package:flutter_app/video/ytdlp/ytdlp_service.dart';
import 'package:flutter_app/video/ytdlp/android_ytdlp.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    MediaKit.ensureInitialized();
  });

  testWidgets('Android E2E: Chaquopy yt-dlp extraction and live playback', (WidgetTester tester) async {
    // 1. Verify AndroidYtDlpService is active
    expect(YtDlpService.instance, isA<AndroidYtDlpService>());
    final androidYtdlp = YtDlpService.instance as AndroidYtDlpService;

    // 2. Check Chaquopy yt-dlp version
    final version = await androidYtdlp.getYtDlpVersion();
    debugPrint('DIAGNOSTICS: Bundled Chaquopy yt-dlp version: $version');
    expect(version, isNotEmpty);

    // 3. Configure schedule with real YouTube ID
    final localDb = LocalDatabaseService();
    localDb.setScheduleData([
      {
        'tournament': 'WTT Android Live Test',
        'year': 2026,
        'team_a': 'Player Alpha',
        'team_b': 'Player Beta',
        'upload_date': '2026-06-01T15:00:00Z',
        'youtube_id': 'jNQXAC9IVRw',
        'is_doubles': false,
        'day': 'Finals',
        'session': 1,
        'video_offset_seconds': 0,
        'match_time': '12:00',
      },
    ]);
    DatabaseService.instance = localDb;
    await filterController.fetchData();

    // 4. Launch App on Android
    await tester.pumpWidget(const WttApp());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // 5. Verify match title is displayed
    expect(find.text('Player Alpha vs Player Beta'), findsWidgets);

    // 6. Verify native MediaKit video widget mounted
    final videoFinder = find.descendant(of: find.byType(VideoHero), matching: find.byType(Video));
    expect(videoFinder, findsOneWidget);

    final dynamic videoWidget = tester.widget(videoFinder);
    final Player player = videoWidget.controller.player;

    // 7. Poll player state for playback (giving Chaquopy yt-dlp extraction up to 30s)
    bool isPlaying = false;
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      debugPrint('[$i] Android Player: playing=${player.state.playing}, dur=${player.state.duration.inSeconds}s, pos=${player.state.position.inSeconds}s');
      if (player.state.playing && player.state.duration.inSeconds > 0) {
        isPlaying = true;
        break;
      }
    }

    expect(
      isPlaying,
      isTrue,
      reason: 'Chaquopy yt-dlp failed to extract stream or media_kit failed to play on Android',
    );
  });
}
