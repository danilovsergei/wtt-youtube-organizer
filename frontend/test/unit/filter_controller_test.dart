import 'dart:io';
import 'package:flutter_app/services/settings_service.dart';
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

    test('Feeder tournaments are correctly filtered with TournamentType.feeder', () async {
      final tContender = const Tournament(id: 't1', name: 'WTT Contender Lagos', year: 2026, type: TournamentType.contender, location: '');
      final tFeeder = const Tournament(id: 't2', name: 'WTT Feeder Berlin', year: 2026, type: TournamentType.feeder, location: '');

      final m1 = const Match(id: 'm1', title: 'M1', tournamentId: 't1', date: '', time: '', imageUrl: '', tag: 'Singles', day: 'Day 1');
      final m2 = const Match(id: 'm2', title: 'M2', tournamentId: 't2', date: '', time: '', imageUrl: '', tag: 'Singles', day: 'Day 1');

      controller.setDebugData([tContender, tFeeder], [m1, m2]);

      // Both visible by default (no filters)
      expect(controller.availableTournaments.map((t) => t.id), ['t1', 't2']);

      // Select Feeder: ONLY Feeder visible
      controller.toggleType(TournamentType.feeder);
      expect(controller.availableTournaments.map((t) => t.id), ['t2']);
      expect(controller.filteredMatches.map((m) => m.id), ['m2']);

      // Select Contender (both Feeder and Contender active)
      controller.toggleType(TournamentType.contender);
      expect(controller.availableTournaments.map((t) => t.id), ['t1', 't2']);

      // Deselect Feeder: ONLY Contender visible
      controller.toggleType(TournamentType.feeder);
      expect(controller.availableTournaments.map((t) => t.id), ['t1']);
      expect(controller.filteredMatches.map((m) => m.id), ['m1']);
    });

    test('Youth tournaments are filtered out of regular Smash and Contender filters', () async {
      final tSmash = const Tournament(id: 't1', name: 'China Smash', year: 2026, type: TournamentType.smash, location: '');
      final tYouthSmash = const Tournament(id: 't2', name: 'China Youth Smash', year: 2026, type: TournamentType.youthContender, location: '');
      final tContender = const Tournament(id: 't3', name: 'WTT Contender Lagos', year: 2026, type: TournamentType.contender, location: '');
      final tYouthContender = const Tournament(id: 't4', name: 'WTT Youth Star Contender', year: 2026, type: TournamentType.youthContender, location: '');

      final m1 = const Match(id: 'm1', title: 'M1', tournamentId: 't1', date: '', time: '', imageUrl: '', tag: 'Singles', day: 'Day 1');
      final m2 = const Match(id: 'm2', title: 'M2', tournamentId: 't2', date: '', time: '', imageUrl: '', tag: 'Singles', day: 'Day 1');
      final m3 = const Match(id: 'm3', title: 'M3', tournamentId: 't3', date: '', time: '', imageUrl: '', tag: 'Singles', day: 'Day 1');
      final m4 = const Match(id: 'm4', title: 'M4', tournamentId: 't4', date: '', time: '', imageUrl: '', tag: 'Singles', day: 'Day 1');

      controller.setDebugData(
        [tSmash, tYouthSmash, tContender, tYouthContender],
        [m1, m2, m3, m4],
      );

      // Default (no filter): regular tournaments visible, youth hidden
      expect(controller.availableTournaments.map((t) => t.id), ['t1', 't3']);
      expect(controller.filteredMatches.map((m) => m.id), ['m1', 'm3']);

      // Select Smash: ONLY regular Smash visible
      controller.toggleType(TournamentType.smash);
      expect(controller.availableTournaments.map((t) => t.id), ['t1']);
      expect(controller.filteredMatches.map((m) => m.id), ['m1']);

      // Select Contender (now Smash & Contender): ONLY regular Smash and regular Contender visible
      controller.toggleType(TournamentType.contender);
      expect(controller.availableTournaments.map((t) => t.id), ['t1', 't3']);
      expect(controller.filteredMatches.map((m) => m.id), ['m1', 'm3']);

      // Deselect Smash: ONLY regular Contender visible
      controller.toggleType(TournamentType.smash);
      expect(controller.availableTournaments.map((t) => t.id), ['t3']);
      expect(controller.filteredMatches.map((m) => m.id), ['m3']);

      // Select Youth: ONLY youth tournaments visible
      controller.toggleType(TournamentType.contender); // Deselect contender
      controller.toggleType(TournamentType.youthContender);
      expect(controller.availableTournaments.map((t) => t.id), ['t2', 't4']);
      expect(controller.filteredMatches.map((m) => m.id), ['m2', 'm4']);
    });

    test('Tournament type filtering persists to SettingsService and reloads in new controller', () async {
      final tempDir = Directory.systemTemp.createTempSync('filter_test_');
      final tempFile = File('${tempDir.path}/test_settings.json');
      SettingsService.instance.customSettingsPath = tempFile.path;

      try {
        controller.toggleType(TournamentType.smash);
        controller.toggleType(TournamentType.champions);

        await Future.delayed(const Duration(milliseconds: 200));

        final newController = FilterController();
        expect(newController.selectedTypes, isEmpty);

        await newController.loadSettings();
        expect(newController.selectedTypes, {TournamentType.smash, TournamentType.champions});

        newController.reset();
        await Future.delayed(const Duration(milliseconds: 200));

        final thirdController = FilterController();
        await thirdController.loadSettings();
        expect(thirdController.selectedTypes, isEmpty);
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
        SettingsService.instance.customSettingsPath = null;
      }
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
    test('Match duration formatting and parsing', () {
      const matchWithMinutes = Match(
        id: 'm1',
        title: 'Player A vs Player B',
        tournamentId: 't1',
        date: '2026-04-01',
        time: '19:00',
        imageUrl: 'https://example.com/1.jpg',
        tag: 'Singles',
        day: 'Day 1',
        durationSeconds: 2700,
      );
      expect(matchWithMinutes.durationFormatted, '45m');

      const matchWithHours = Match(
        id: 'm2',
        title: 'Player C vs Player D',
        tournamentId: 't1',
        date: '2026-04-01',
        time: '20:00',
        imageUrl: 'https://example.com/2.jpg',
        tag: 'Singles',
        day: 'Day 1',
        durationSeconds: 4500,
      );
      expect(matchWithHours.durationFormatted, '1h 15m');

      const matchExactHours = Match(
        id: 'm3',
        title: 'Player E vs Player F',
        tournamentId: 't1',
        date: '2026-04-01',
        time: '21:00',
        imageUrl: 'https://example.com/3.jpg',
        tag: 'Singles',
        day: 'Day 1',
        durationSeconds: 3600,
      );
      expect(matchExactHours.durationFormatted, '1h');

      const matchZero = Match(
        id: 'm4',
        title: 'Player G vs Player H',
        tournamentId: 't1',
        date: '2026-04-01',
        time: '22:00',
        imageUrl: 'https://example.com/4.jpg',
        tag: 'Singles',
        day: 'Day 1',
        durationSeconds: 0,
      );
      expect(matchZero.durationFormatted, '');
    });

    test('Search by tournament name filters availableTournaments and matches', () async {
      controller.customDataFetcher = () async => [
        {
          'tournament': 'WTT Champions Montpellier',
          'year': 2026,
          'location': 'Montpellier, France',
          'team_a': 'Felix Lebrun',
          'team_b': 'Anders Lind',
          'upload_date': '2026-10-28T10:00:00Z',
          'youtube_id': 'yt_mont',
          'is_doubles': false,
          'day': 'Day 2',
        },
        {
          'tournament': 'China Smash',
          'year': 2026,
          'location': 'Beijing, China',
          'team_a': 'Ma Long',
          'team_b': 'Lin Shidong',
          'upload_date': '2026-10-01T10:00:00Z',
          'youtube_id': 'yt_china',
          'is_doubles': false,
          'day': 'Day 1',
        },
      ];

      await controller.fetchData();
      expect(controller.availableTournaments.length, 2);

      // Search tournament by name
      controller.setSearchQuery('montpellier');
      expect(controller.availableTournaments.length, 1);
      expect(controller.availableTournaments.first.name, 'WTT Champions Montpellier');

      // Matches for Montpellier include its match
      final montMatches = controller.getMatchesForTournament(controller.availableTournaments.first.id);
      expect(montMatches.length, 1);
      expect(montMatches.first.title, contains('Felix Lebrun'));

      // Clearing search restores both tournaments
      controller.setSearchQuery('');
      expect(controller.availableTournaments.length, 2);
    });

    test('Search by player name filters tournaments and matches', () async {
      controller.customDataFetcher = () async => [
        {
          'tournament': 'WTT Champions Montpellier',
          'year': 2026,
          'location': 'Montpellier, France',
          'team_a': 'Felix Lebrun',
          'team_b': 'Anders Lind',
          'upload_date': '2026-10-28T10:00:00Z',
          'youtube_id': 'yt_mont',
          'is_doubles': false,
          'day': 'Day 2',
        },
        {
          'tournament': 'China Smash',
          'year': 2026,
          'location': 'Beijing, China',
          'team_a': 'Ma Long',
          'team_b': 'Lin Shidong',
          'upload_date': '2026-10-01T10:00:00Z',
          'youtube_id': 'yt_china',
          'is_doubles': false,
          'day': 'Day 1',
        },
      ];

      await controller.fetchData();

      // Search by player name (case-insensitive)
      controller.setSearchQuery('shidong');

      // Only China Smash had Lin Shidong
      expect(controller.availableTournaments.length, 1);
      expect(controller.availableTournaments.first.name, 'China Smash');

      // China Smash matches show Lin Shidong
      final chinaMatches = controller.getMatchesForTournament(controller.availableTournaments.first.id);
      expect(chinaMatches.length, 1);
      expect(chinaMatches.first.title, contains('Lin Shidong'));

      // Active search auto-expands days
      expect(controller.isDayExpanded(controller.availableTournaments.first.id, 'Day 1'), isTrue);

      // Search for player with no matches returns 0
      controller.setSearchQuery('nonexistent player');
      expect(controller.availableTournaments.length, 0);
    });

    test('Multi-player head-to-head word search (e.g. Lebrun Lind)', () async {
      controller.customDataFetcher = () async => [
        {
          'tournament': 'WTT Champions Montpellier',
          'year': 2026,
          'location': 'Montpellier, France',
          'team_a': 'Felix Lebrun',
          'team_b': 'Anders Lind',
          'upload_date': '2026-10-28T10:00:00Z',
          'youtube_id': 'yt_mont',
          'is_doubles': false,
          'day': 'Day 2',
        },
        {
          'tournament': 'WTT Champions Montpellier',
          'year': 2026,
          'location': 'Montpellier, France',
          'team_a': 'Felix Lebrun',
          'team_b': 'Truls Moregard',
          'upload_date': '2026-10-28T11:00:00Z',
          'youtube_id': 'yt_mont_2',
          'is_doubles': false,
          'day': 'Day 2',
        },
        {
          'tournament': 'China Smash',
          'year': 2026,
          'location': 'Beijing, China',
          'team_a': 'Ma Long',
          'team_b': 'Lin Shidong',
          'upload_date': '2026-10-01T10:00:00Z',
          'youtube_id': 'yt_china',
          'is_doubles': false,
          'day': 'Day 1',
        },
      ];

      await controller.fetchData();
      final montId = controller.allTournaments.firstWhere((t) => t.name == 'WTT Champions Montpellier').id;

      // 1. Searching "Lebrun Lind" finds specifically Felix Lebrun vs Anders Lind
      controller.setSearchQuery('Lebrun Lind');
      final headToHeadMatches = controller.getMatchesForTournament(montId);
      expect(headToHeadMatches.length, 1);
      expect(headToHeadMatches.first.title, contains('Anders Lind'));

      // 2. Searching "Felix Montpellier" matches via player + tournament name
      controller.setSearchQuery('Felix Montpellier');
      expect(controller.getMatchesForTournament(montId).length, 2);

      // 3. Searching substring "lin" matches "Anders Lind" and "Lin Shidong"
      controller.setSearchQuery('Lebrun Lin');
      expect(controller.getMatchesForTournament(montId).length, 1);
      expect(controller.getMatchesForTournament(montId).first.title, contains('Anders Lind'));

      // 4. Searching players who never played each other returns 0
      controller.setSearchQuery('Lind Shidong');
      expect(controller.getMatchesForTournament(montId).length, 0);
    });

    test('Searching player with multiple matches shows tournaments unexpanded, and keeps days collapsed', () async {
      controller.customDataFetcher = () async => [
        {
          'tournament': 'WTT Champions Montpellier',
          'year': 2026,
          'location': 'Montpellier, France',
          'team_a': 'Felix Lebrun',
          'team_b': 'Anders Lind',
          'upload_date': '2026-10-28T10:00:00Z',
          'youtube_id': 'yt_mont',
          'is_doubles': false,
          'day': 'Day 2',
        },
        {
          'tournament': 'WTT Champions Montpellier',
          'year': 2026,
          'location': 'Montpellier, France',
          'team_a': 'Felix Lebrun',
          'team_b': 'Truls Moregard',
          'upload_date': '2026-10-28T11:00:00Z',
          'youtube_id': 'yt_mont_2',
          'is_doubles': false,
          'day': 'Day 1',
        },
        {
          'tournament': 'Singapore Smash',
          'year': 2026,
          'location': 'Singapore',
          'team_a': 'Alexis Lebrun',
          'team_b': 'Feng Yi-Hsin',
          'upload_date': '2026-03-01T10:00:00Z',
          'youtube_id': 'yt_sing',
          'is_doubles': false,
          'day': 'Day 3',
        },
        {
          'tournament': 'China Smash',
          'year': 2026,
          'location': 'Beijing, China',
          'team_a': 'Ma Long',
          'team_b': 'Lin Shidong',
          'upload_date': '2026-10-01T10:00:00Z',
          'youtube_id': 'yt_china',
          'is_doubles': false,
          'day': 'Day 1',
        },
      ];

      await controller.fetchData();

      // 1. Searching "Lebrun" matches multiple tournaments and matches
      controller.setSearchQuery('Lebrun');

      // Tournaments list shows all tournaments where Lebrun played
      expect(controller.availableTournaments.length, 2);
      expect(controller.availableTournaments.map((t) => t.name), containsAll(['WTT Champions Montpellier', 'Singapore Smash']));

      // Does NOT auto-navigate to a specific tournament because multiple matches match!
      expect(controller.selectedTournamentId, isEmpty);

      // Days are NOT auto-expanded (keeps them collapsed to avoid spoilers)
      final montId = controller.allTournaments.firstWhere((t) => t.name == 'WTT Champions Montpellier').id;
      expect(controller.isDayExpanded(montId, 'Day 1'), isFalse);
      expect(controller.isDayExpanded(montId, 'Day 2'), isFalse);

      // 2. Searching specific matchup "Lebrun Lindt" yields exactly 1 match
      controller.setSearchQuery('Lebrun Lind');

      // Exactly 1 match found: auto-selects tournament and auto-expands that day!
      expect(controller.selectedTournamentId, montId);
      expect(controller.isDayExpanded(montId, 'Day 2'), isTrue);
      expect(controller.selectedMatch?.title, contains('Anders Lind'));
    });

    test('Comprehensive search coverage: 1-word, 2-words, substring inside words, whitespace, doubles isolation, and negative cases', () async {
      controller.customDataFetcher = () async => [
        {
          'tournament': 'WTT Champions Montpellier',
          'year': 2026,
          'location': 'Montpellier, France',
          'team_a': 'Felix Lebrun',
          'team_b': 'Anders Lind',
          'upload_date': '2026-10-28T10:00:00Z',
          'youtube_id': 'yt_mont_1',
          'is_doubles': false,
          'day': 'Day 2',
        },
        {
          'tournament': 'WTT Champions Montpellier',
          'year': 2026,
          'location': 'Montpellier, France',
          'team_a': 'Felix Lebrun',
          'team_b': 'Truls Moregard',
          'upload_date': '2026-10-28T11:00:00Z',
          'youtube_id': 'yt_mont_2',
          'is_doubles': false,
          'day': 'Day 1',
        },
        {
          'tournament': 'China Smash',
          'year': 2026,
          'location': 'Beijing, China',
          'team_a': 'Ma Long',
          'team_b': 'Lin Shidong',
          'upload_date': '2026-10-01T10:00:00Z',
          'youtube_id': 'yt_china_1',
          'is_doubles': false,
          'day': 'Day 1',
        },
        {
          'tournament': 'China Smash',
          'year': 2026,
          'location': 'Beijing, China',
          'team_a': 'Alexis Lebrun & Camille Lutz',
          'team_b': 'Cheng I-Ching & Lin Yun-Ju',
          'upload_date': '2026-10-02T10:00:00Z',
          'youtube_id': 'yt_china_2',
          'is_doubles': true,
          'day': 'Day 2',
        },
      ];

      await controller.fetchData();
      final montId = controller.allTournaments.firstWhere((t) => t.name == 'WTT Champions Montpellier').id;
      final chinaId = controller.allTournaments.firstWhere((t) => t.name == 'China Smash').id;

      // --- 1. One-Word Tournament Search ---
      controller.setSearchQuery('montpellier');
      expect(controller.availableTournaments.length, 1);
      expect(controller.availableTournaments.first.id, montId);

      // --- 2. One-Word Player Search ---
      controller.setSearchQuery('Moregard');
      expect(controller.availableTournaments.length, 1);
      expect(controller.availableTournaments.first.id, montId);
      final moregardMatches = controller.getMatchesForTournament(montId);
      expect(moregardMatches.length, 1);
      expect(moregardMatches.first.title, contains('Truls Moregard'));

      // --- 3. Two-Words Head-to-Head Search (Any Player Order) ---
      controller.setSearchQuery('Felix Lind');
      expect(controller.filteredMatches.length, 1);
      expect(controller.filteredMatches.first.title, contains('Anders Lind'));

      controller.setSearchQuery('Lind Felix'); // Reversed player order
      expect(controller.filteredMatches.length, 1);
      expect(controller.filteredMatches.first.title, contains('Felix Lebrun'));

      // --- 4. Two-Words Player + Tournament Search ---
      controller.setSearchQuery('Shidong China');
      expect(controller.availableTournaments.length, 1);
      expect(controller.availableTournaments.first.id, chinaId);
      expect(controller.filteredMatches.length, 1);

      // --- 5. Middle Substring Matching Inside Player Names and Tournament Names ---
      controller.setSearchQuery('dong'); // Substring inside "Lin Shidong"
      expect(controller.availableTournaments.length, 1);
      expect(controller.availableTournaments.first.id, chinaId);
      expect(controller.getMatchesForTournament(chinaId).first.title, contains('Shidong'));

      controller.setSearchQuery('pellier'); // Substring inside "Montpellier"
      expect(controller.availableTournaments.length, 1);
      expect(controller.availableTournaments.first.id, montId);

      // --- 6. Whitespace and Case Resilience ---
      controller.setSearchQuery('   fElIx    lInD   ');
      expect(controller.filteredMatches.length, 1);
      expect(controller.filteredMatches.first.title, contains('Anders Lind'));

      // --- 7. Singles vs Doubles Isolation During Search ---
      // When showDoubles is false (default), searching for a player who only played in doubles returns 0 matches
      controller.setSearchQuery('Lutz');
      expect(controller.availableTournaments.length, 0); // China Smash hidden because Lutz only played doubles!
      expect(controller.filteredMatches.length, 0);

      // When showDoubles is enabled, China Smash and the Lutz doubles match appear!
      controller.toggleShowDoubles();
      expect(controller.availableTournaments.length, 1);
      expect(controller.availableTournaments.first.id, chinaId);
      expect(controller.getMatchesForTournament(chinaId).length, 1);
      expect(controller.getMatchesForTournament(chinaId).first.title, contains('Camille Lutz'));

      // Reset doubles back to false for further checks
      controller.toggleShowDoubles();

      // --- 8. Negative Search Cases ---
      // Two players who never played against each other
      controller.setSearchQuery('Lind Shidong');
      expect(controller.availableTournaments.length, 0);
      expect(controller.filteredMatches.length, 0);

      // Completely nonexistent name
      controller.setSearchQuery('NonExistentPlayer 999');
      expect(controller.availableTournaments.length, 0);
      expect(controller.filteredMatches.length, 0);

      // --- 9. Clearing Search Query ---
      controller.setSearchQuery('');
      expect(controller.availableTournaments.length, 2); // Both Montpellier and China Smash are visible
      expect(controller.selectedTournamentId, isEmpty);  // Returns to unexpanded tournament list
    });
  });
}
