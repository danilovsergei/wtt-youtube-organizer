import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_app/main.dart';

void main() {
  final mockTournaments = [
    const Tournament(
      id: 't1',
      name: 'WTT Champions Test',
      year: 2026,
      type: TournamentType.champions,
      location: 'Test Location',
    ),
  ];

  final mockMatches = [
    Match(
      id: 'm1',
      title: 'Match 1',
      tournamentId: 't1',
      date: '2026-01-15',
      time: '20:00',
      imageUrl: '',
      tag: 'Singles',
      day: 'Day 1',
      session: 1,
      effectiveTimestamp: DateTime.parse('2026-01-18T10:00:00Z'), // Latest timestamp (Day 1 streamed last)
    ),
    Match(
      id: 'm2',
      title: 'Match 2',
      tournamentId: 't1',
      date: '2026-01-15',
      time: '21:00',
      imageUrl: '',
      tag: 'Singles',
      day: 'Q Day 1',
      session: 2,
      effectiveTimestamp: DateTime.parse('2026-01-14T11:00:00Z'), // Second Oldest
    ),
    Match(
      id: 'm3',
      title: 'Match 3',
      tournamentId: 't1',
      date: '2026-01-15',
      time: '22:00',
      imageUrl: '',
      tag: 'Singles',
      day: 'Q Day 1',
      session: 3,
      effectiveTimestamp: DateTime.parse('2026-01-14T11:00:00Z'), // Ties with m2, but has higher session
    ),
    Match(
      id: 'm4',
      title: 'Match 4',
      tournamentId: 't1',
      date: '2026-01-16',
      time: '18:00',
      imageUrl: '',
      tag: 'Singles',
      day: 'Q Day 2',
      session: 1,
      effectiveTimestamp: DateTime.parse('2026-01-12T10:00:00Z'), // Oldest (Streamed before everything)
    ),
    Match(
      id: 'm5',
      title: 'Match 5',
      tournamentId: 't1',
      date: '2026-01-16',
      time: '19:00',
      imageUrl: '',
      tag: 'Singles',
      day: 'Day 4 Finals',
      session: 1,
      effectiveTimestamp: DateTime.parse('2026-01-16T10:00:00Z'), // Middle
    ),
  ];

  setUp(() {
    filterController.setDebugData(mockTournaments, mockMatches);
  });

  testWidgets('Groups matches by effective timestamp and session, sorting properly', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const WttApp());
    await tester.pump();

    // Select tournament
    final tournamentFinder = find.text('WTT Champions Test').first;
    expect(tournamentFinder, findsOneWidget);
    await tester.tap(tournamentFinder);
    await tester.pump();

    // Verify all group headers are present
    expect(find.text('Day 1 - Round 1'), findsOneWidget);
    expect(find.text('Day 4 Finals - Round 1'), findsOneWidget);
    expect(find.text('Q Day 1 - Round 3'), findsOneWidget);
    expect(find.text('Q Day 1 - Round 2'), findsOneWidget);
    expect(find.text('Q Day 2 - Round 1'), findsOneWidget);

    // Verify ordering by their vertical positions. Descending by effectiveTimestamp
    // 1. Day 1 (2026-01-18)
    // 2. Day 4 Finals (2026-01-16)
    // 3. Q Day 1 - Round 3 (2026-01-14) (Tie, but higher session)
    // 4. Q Day 1 - Round 2 (2026-01-14)
    // 5. Q Day 2 (2026-01-12)
    final dyDay1 = tester.getTopLeft(find.text('Day 1 - Round 1')).dy;
    final dyDay4 = tester.getTopLeft(find.text('Day 4 Finals - Round 1')).dy;
    final dyQDay1R3 = tester.getTopLeft(find.text('Q Day 1 - Round 3')).dy;
    final dyQDay1R2 = tester.getTopLeft(find.text('Q Day 1 - Round 2')).dy;
    final dyQDay2 = tester.getTopLeft(find.text('Q Day 2 - Round 1')).dy;

    expect(dyDay1 < dyDay4, isTrue, reason: 'Day 1 should be before Day 4 Finals');
    expect(dyDay4 < dyQDay1R3, isTrue, reason: 'Day 4 Finals should be before Q Day 1 - Round 3');
    expect(dyQDay1R3 < dyQDay1R2, isTrue, reason: 'Q Day 1 - Round 3 should be before Q Day 1 - Round 2');
    expect(dyQDay1R2 < dyQDay2, isTrue, reason: 'Q Day 1 - Round 2 should be before Q Day 2');
  });
}

