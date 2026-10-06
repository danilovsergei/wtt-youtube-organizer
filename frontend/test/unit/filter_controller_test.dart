import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/main.dart';

void main() {
  group('FilterController Unit Tests', () {
    late FilterController controller;

    setUp(() {
      controller = FilterController();
    });

    test('Initial state defaults', () {
      expect(controller.isLoading, isTrue);
      expect(controller.selectedYears, {2025, 2026});
      expect(controller.selectedTypes, isEmpty);
      expect(controller.selectedTournamentId, isEmpty);
      expect(controller.showSingles, isTrue);
      expect(controller.showDoubles, isFalse);
      expect(controller.searchQuery, isEmpty);
      expect(controller.allTournaments, isEmpty);
      expect(controller.allMatches, isEmpty);
    });

    test('fetchData parses rows, groups tournaments, and sets initial selected match', () async {
      controller.customDataFetcher = () async => [
        {
          'tournament': 'WTT Champions Chongqing',
          'year': 2026,
          'location': 'Chongqing, China',
          'team_a': 'Wang Chuqin',
          'team_b': 'Fan Zhendong',
          'upload_date': '2026-06-01T10:00:00Z',
          'youtube_id': 'yt_1',
          'is_doubles': false,
          'day': 'Day 4 Finals',
        },
        {
          'tournament': 'China Smash',
          'year': 2025,
          'location': 'Beijing, China',
          'video_title': 'Sun Yingsha vs Wang Manyu',
          'upload_date': '2025-10-01T10:00:00Z',
          'youtube_id': 'yt_2',
          'is_doubles': false,
          'day': 'Day 1',
        },
      ];

      await controller.fetchData();

      expect(controller.isLoading, isFalse);
      expect(controller.allTournaments.length, 2);
      expect(controller.allMatches.length, 2);

      // Check tournament type inference
      final chongqing = controller.allTournaments.firstWhere((t) => t.name == 'WTT Champions Chongqing');
      expect(chongqing.type, TournamentType.champions);
      expect(chongqing.year, 2026);

      final beijing = controller.allTournaments.firstWhere((t) => t.name == 'China Smash');
      expect(beijing.type, TournamentType.smash);
      expect(beijing.year, 2025);

      // Check match formatting
      expect(controller.allMatches.first.title, 'Wang Chuqin vs Fan Zhendong');
      expect(controller.selectedMatch.title, 'Wang Chuqin vs Fan Zhendong');
    });

    test('Year filtering toggles correctly', () {
      controller.toggleYear(2026); // Remove 2026
      expect(controller.selectedYears, {2025});

      controller.toggleYear(2024); // Add 2024
      expect(controller.selectedYears, {2025, 2024});

      controller.toggleYear(2025); // Remove 2025
      controller.toggleYear(2024); // Remove 2024
      expect(controller.selectedYears, isEmpty); // Empty = All years
    });

    test('Tournament type filtering toggles correctly', () {
      controller.toggleType(TournamentType.champions);
      expect(controller.selectedTypes, {TournamentType.champions});

      controller.toggleType(TournamentType.smash);
      expect(controller.selectedTypes, {TournamentType.champions, TournamentType.smash});

      controller.toggleType(TournamentType.champions);
      expect(controller.selectedTypes, {TournamentType.smash});
    });

    test('Singles and Doubles toggles update filtered matches', () {
      final t1 = const Tournament(id: 't1', name: 'T1', year: 2026, type: TournamentType.champions, location: '');
      final singlesMatch = const Match(
        id: 'm1',
        title: 'Singles Final',
        tournamentId: 't1',
        date: '2026-01-01',
        time: '12:00',
        imageUrl: '',
        tag: 'Singles',
        day: 'Day 1',
      );
      final doublesMatch = const Match(
        id: 'm2',
        title: 'Doubles Final',
        tournamentId: 't1',
        date: '2026-01-01',
        time: '13:00',
        imageUrl: '',
        tag: 'Doubles',
        day: 'Day 1',
      );

      controller.setDebugData([t1], [singlesMatch, doublesMatch]);

      // Default: singles true, doubles false
      expect(controller.filteredMatches.map((m) => m.id), ['m1']);

      // Enable doubles
      controller.toggleShowDoubles();
      expect(controller.filteredMatches.map((m) => m.id), ['m1', 'm2']);

      // Disable singles
      controller.toggleShowSingles();
      expect(controller.filteredMatches.map((m) => m.id), ['m2']);
    });

    test('Search query filters by player and tournament name', () {
      final t1 = const Tournament(id: 't1', name: 'WTT Macao', year: 2026, type: TournamentType.champions, location: '');
      final t2 = const Tournament(id: 't2', name: 'WTT Singapore', year: 2026, type: TournamentType.smash, location: '');

      final m1 = const Match(
        id: 'm1',
        title: 'Felix Lebrun vs Hugo Calderano',
        tournamentId: 't1',
        date: '', time: '', imageUrl: '', tag: 'Singles', day: 'Day 1',
      );
      final m2 = const Match(
        id: 'm2',
        title: 'Harimoto vs Lin Shidong',
        tournamentId: 't2',
        date: '', time: '', imageUrl: '', tag: 'Singles', day: 'Day 1',
      );

      controller.setDebugData([t1, t2], [m1, m2]);

      controller.setSearchQuery('lebrun');
      expect(controller.filteredMatches.length, 1);
      expect(controller.filteredMatches.first.id, 'm1');

      controller.setSearchQuery('singapore'); // Search by tournament name
      expect(controller.filteredMatches.length, 1);
      expect(controller.filteredMatches.first.id, 'm2');

      controller.setSearchQuery('');
      expect(controller.filteredMatches.length, 2);
    });

    test('Match state is preserved when re-fetching data', () async {
      final rows1 = [
        {'tournament': 'T1', 'year': 2026, 'video_title': 'Match 1', 'upload_date': '2026-01-01', 'youtube_id': 'yt_1', 'is_doubles': false, 'day': 'Day 1'},
        {'tournament': 'T1', 'year': 2026, 'video_title': 'Match 2', 'upload_date': '2026-01-02', 'youtube_id': 'yt_2', 'is_doubles': false, 'day': 'Day 1'},
      ];
      controller.customDataFetcher = () async => rows1;
      await controller.fetchData();

      // User selects Match 2
      final match2 = controller.allMatches.firstWhere((m) => m.youtubeId == 'yt_2');
      controller.selectMatch(match2);
      expect(controller.selectedMatch.youtubeId, 'yt_2');

      // Now server updates with a new match at the top
      final rows2 = [
        {'tournament': 'T1', 'year': 2026, 'video_title': 'New Match 3', 'upload_date': '2026-01-03', 'youtube_id': 'yt_3', 'is_doubles': false, 'day': 'Day 1'},
        ...rows1,
      ];
      controller.customDataFetcher = () async => rows2;
      await controller.fetchData();

      // Verify selectedMatch did NOT reset to New Match 3, but stayed re-linked to yt_2!
      expect(controller.selectedMatch.youtubeId, 'yt_2');
    });

    test('Day expansion toggle and tournament selection', () {
      expect(controller.isDayExpanded('t1', 'Day 1'), isFalse);

      controller.toggleDay('t1', 'Day 1');
      expect(controller.isDayExpanded('t1', 'Day 1'), isTrue);

      controller.toggleDay('t1', 'Day 1');
      expect(controller.isDayExpanded('t1', 'Day 1'), isFalse);

      // Selecting a tournament clears expanded days
      controller.toggleDay('t1', 'Day 1');
      controller.selectTournament('t2');
      expect(controller.isDayExpanded('t1', 'Day 1'), isFalse);
      expect(controller.selectedTournamentId, 't2');

      // Clicking same tournament deselects it
      controller.selectTournament('t2');
      expect(controller.selectedTournamentId, isEmpty);
    });

    test('Reset clears all filters to defaults', () {
      controller.toggleYear(2026);
      controller.toggleType(TournamentType.smash);
      controller.selectTournament('t1');
      controller.setSearchQuery('search');
      controller.toggleShowDoubles();

      controller.reset();

      expect(controller.selectedYears, {2025, 2026});
      expect(controller.selectedTypes, isEmpty);
      expect(controller.selectedTournamentId, isEmpty);
      expect(controller.showSingles, isTrue);
      expect(controller.showDoubles, isFalse);
      expect(controller.searchQuery, isEmpty);
    });
  });
}
