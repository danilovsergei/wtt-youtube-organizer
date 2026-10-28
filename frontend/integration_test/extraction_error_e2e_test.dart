import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_app/data/database_service.dart';
import 'package:flutter_app/data/local_database.dart';
import 'package:flutter_app/video/ytdlp/ytdlp_service.dart';
import 'package:flutter_app/video/ytdlp/test_ytdlp.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    MediaKit.ensureInitialized();
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      await windowManager.ensureInitialized();
    }
  });

  testWidgets('E2E: yt-dlp extraction failure renders error overlay with details on top of video window', (tester) async {
    // 1. Setup local mock database
    DatabaseService.instance = LocalDatabaseService(
      localJsonPath: 'test/assets/mock_schedule.json',
    );

    // 2. Setup mock YtDlpService simulating YouTube bot challenge error
    const botErrorMsg = "ERROR: [youtube] AOyf5JL_DtI: Sign in to confirm you're not a bot. Use --cookies-from-browser or --cookies for the authentication.";
    final mockYtdlp = TestYtDlpService()
      ..mockError = const ProcessException(
        'yt-dlp',
        ['-j', 'https://www.youtube.com/watch?v=AOyf5JL_DtI'],
        botErrorMsg,
        1,
      );
    YtDlpService.instance = mockYtdlp;

    // 3. Launch App
    await tester.pumpWidget(const WttApp());
    await filterController.fetchData();
    await tester.pumpAndSettle();

    // 4. Initially cold start banner is shown, no error overlay
    expect(find.byKey(const Key('cold_start_banner')), findsOneWidget);
    expect(find.byKey(const Key('video_error_overlay')), findsNothing);

    // 5. Select tournament then select match to trigger extraction
    final tournament = filterController.allTournaments.first;
    await filterController.selectTournament(tournament.id);
    final match = filterController.allMatches.first;
    filterController.selectMatch(match);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    // 6. Verify error overlay appears on top of the video window
    expect(find.byKey(const Key('video_error_overlay')), findsOneWidget, reason: 'Error overlay must appear when extraction fails');
    expect(find.text('Playback / Extraction Error'), findsOneWidget);
    expect(find.textContaining("Sign in to confirm you're not a bot"), findsOneWidget, reason: 'Exact bot challenge error must be displayed');
    expect(find.text('Retry'), findsOneWidget);

    // 7. Verify Retry functionality: clear mock error and tap Retry
    mockYtdlp.mockError = null;
    final retryButton = find.text('Retry');
    await tester.tap(retryButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Error overlay should be dismissed and loading resumes
    expect(find.byKey(const Key('video_error_overlay')), findsNothing, reason: 'Error overlay should dismiss upon retrying');
  });
}
