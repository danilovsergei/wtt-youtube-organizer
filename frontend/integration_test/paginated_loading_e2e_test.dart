import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_app/data/database_service.dart';
import 'package:flutter_app/data/prod_database.dart';
import 'package:flutter_app/video/ytdlp/ytdlp_service.dart';
import 'package:flutter_app/video/ytdlp/test_ytdlp.dart';
import 'package:flutter_app/widgets/tv_focusable.dart';
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

  testWidgets('Paginated loading E2E: initial batch, scroll loading, and on-demand match fetching', (tester) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    int tournamentsRequestCount = 0;
    int matchesRequestCount = 0;
    final List<int> requestedOffsets = [];

    server.listen((HttpRequest request) async {
      request.response.headers.contentType = ContentType.json;

      if (request.uri.path.contains('v_tournaments')) {
        tournamentsRequestCount++;
        final offset = int.tryParse(request.uri.queryParameters['offset'] ?? '') ?? 0;
        final limit = int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 20;
        requestedOffsets.add(offset);

        final list = List.generate(limit, (i) {
          final idx = offset + i;
          return {
            'id': 't_$idx',
            'name': 'WTT Tournament $idx',
            'year': 2026,
            'match_count': 3,
            'last_upload': '2026-10-14T10:00:00Z',
          };
        });
        request.response.headers.set('content-range', '$offset-${offset + limit - 1}/100');
        request.response.write(jsonEncode(list));
      } else if (request.uri.path.contains('v_tournament_schedule')) {
        matchesRequestCount++;
        final tournamentParam = request.uri.queryParameters['tournament'] ?? '';
        final name = tournamentParam.replaceAll('eq.', '');
        final list = [
          {
            'tournament': name,
            'year': 2026,
            'day': 'Day 1 Finals',
            'session': null,
            'team_a': 'Player Alpha',
            'team_b': 'Player Beta',
            'youtube_id': 'test_yt_mock',
            'video_offset_seconds': 0,
            'duration_seconds': 1200,
          }
        ];
        request.response.write(jsonEncode(list));
      } else {
        request.response.write('[]');
      }
      await request.response.close();
    });

    try {
      // Configure ProdDatabaseService pointed to our mock REST server
      DatabaseService.instance = ProdDatabaseService(
        customUrl: 'http://127.0.0.1:$port',
        customKey: 'mock-test-key',
      );
      YtDlpService.instance = TestYtDlpService();

      // Launch app
      await tester.pumpWidget(const WttApp());
      await filterController.fetchData();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));

      // =======================================================================
      // STEP 1: Verify Initial Batch of Tournaments
      // =======================================================================
      expect(tournamentsRequestCount, 1, reason: 'Exactly one initial batch request should be made');
      expect(requestedOffsets.first, 0, reason: 'Initial batch must start at offset 0');
      expect(find.text('WTT Tournament 0'), findsOneWidget, reason: 'First tournament of batch 1 should be visible');
      expect(find.text('WTT Tournament 20'), findsNothing, reason: 'Page 2 tournaments must not be loaded yet');

      // =======================================================================
      // STEP 2: Verify Scrolling Loads New Tournaments (Infinite Scroll)
      // =======================================================================
      final scrollableFinder = find.byType(SingleChildScrollView).first;
      expect(scrollableFinder, findsOneWidget);

      // Perform real drag gesture down to trigger onScroll threshold
      await tester.drag(scrollableFinder, const Offset(0, -800));
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));

      expect(tournamentsRequestCount, greaterThanOrEqualTo(2), reason: 'Scrolling down should trigger pagination');
      expect(requestedOffsets, contains(20), reason: 'Second batch must start at offset 20');

      // Verify that second batch tournament is now loaded and visible in sidebar
      final tourney20Finder = find.widgetWithText(TvFocusable, 'WTT Tournament 20');
      expect(tourney20Finder, findsWidgets, reason: 'WTT Tournament 20 should appear after scrolling');

      // =======================================================================
      // STEP 3: Verify Opening Tournament Loads Matches On-Demand
      // =======================================================================
      expect(matchesRequestCount, 0, reason: 'Matches must not be loaded before opening tournament');

      await tester.ensureVisible(tourney20Finder.first);
      await tester.tap(tourney20Finder.first);
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));

      expect(matchesRequestCount, 1, reason: 'Opening tournament must make on-demand REST request for matches');

      // Verify days are collapsed by default (anti-spoiler)
      expect(find.text('Player Alpha vs Player Beta'), findsNothing, reason: 'Matches must stay hidden until day expanded');
      final dayHeader = find.widgetWithText(TvFocusable, 'Day 1 Finals');
      expect(dayHeader, findsOneWidget, reason: 'Day 1 Finals header should be visible');

      // Expand Day 1 Finals
      await tester.tap(dayHeader);
      await tester.pump();
      await tester.pumpAndSettle();

      // Verify matches for WTT Tournament 20 are now visible
      expect(find.text('Player Alpha vs Player Beta'), findsOneWidget, reason: 'Matches should appear after expanding day');

    } finally {
      await server.close(force: true);
    }
  });
}
