import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_app/main.dart';

void main() {
  // Mock Data
  final mockTournaments = [
    const Tournament(
      id: 't1',
      name: 'WTT Champions Doha 2026',
      year: 2026,
      type: TournamentType.champions,
      location: 'Doha, Qatar',
    ),
  ];

  final mockMatches = [
    const Match(
      id: 'm1',
      title: 'Men\'s Singles Final: Fan Zhendong vs Wang Chuqin',
      tournamentId: 't1',
      date: '2026-01-15',
      time: '20:00',
      imageUrl: 'https://via.placeholder.com/150',
      tag: 'Singles',
      day: 'Day 1',
      views: '2.1M',
      youtubeId: 'dQw4w9WgXcQ',
    ),
  ];

  setUp(() {
    // Reset controller before each test
    filterController.setDebugData(mockTournaments, mockMatches);
  });

  testWidgets('App renders Match Explorer title', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(const WttApp());
    await tester.pump(); // Allow FutureBuilder/Streams to settle if any

    addTearDown(tester.view.resetPhysicalSize);

    expect(find.text('Match Explorer'), findsOneWidget);
  });

  testWidgets('Sidebar displays list of tournaments', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(const WttApp());
    await tester.pump();

    addTearDown(tester.view.resetPhysicalSize);

    expect(find.text('Tournaments'), findsOneWidget);
    expect(find.text('WTT Champions Doha 2026'), findsWidgets);
  });

  testWidgets('Sidebar expands tournament to show matches', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(const WttApp());
    await tester.pump();

    addTearDown(tester.view.resetPhysicalSize);

    // Find the tournament item in the list
    final tournamentFinder = find.text('WTT Champions Doha 2026').first;
    expect(tournamentFinder, findsOneWidget);

    // Tap to enter tournament detail view
    await tester.tap(tournamentFinder);
    await tester.pump();

    // Verify "Back to Tournaments" button is present
    expect(find.text('Back to Tournaments'), findsOneWidget);

    // Verify day header is present
    final dayFinder = find.text('Day 1');
    expect(dayFinder, findsOneWidget);

    // Matches should NOT be visible in the Sidebar yet (day collapsed)
    // Note: The match might be visible in the main content area, so we scopes the find to Sidebar
    expect(
      find.descendant(
        of: find.byType(Sidebar),
        matching: find.text('Men\'s Singles Final: Fan Zhendong vs Wang Chuqin'),
      ),
      findsNothing,
    );

    // Tap "Day 1" to expand
    await tester.tap(dayFinder);
    await tester.pump();

    // Verify match is now visible in the Sidebar
    expect(
      find.descendant(
        of: find.byType(Sidebar),
        matching: find.text('Men\'s Singles Final: Fan Zhendong vs Wang Chuqin'),
      ),
      findsOneWidget,
    );

    // Verify the expanded icon is present
    expect(find.byIcon(Icons.keyboard_arrow_down), findsWidgets);
  });
}