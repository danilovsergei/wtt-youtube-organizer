import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/data/database_service.dart';
import 'package:flutter_app/data/prod_database.dart';
import 'package:flutter_app/data/local_database.dart';
import 'package:flutter_app/data/mock_schedule.dart';
import 'package:flutter_app/main.dart';

void main() {
  group('DatabaseService & LocalDatabase Unit Tests', () {
    late DatabaseService originalDbService;

    setUp(() {
      originalDbService = DatabaseService.instance;
    });

    tearDown(() {
      DatabaseService.instance = originalDbService;
    });

    test('LocalDatabaseService returns in-memory default mock schedule', () async {
      final localDb = LocalDatabaseService();
      await localDb.initialize();

      final schedule = await localDb.fetchTournamentSchedule();
      expect(schedule.isNotEmpty, isTrue);
      expect(schedule.length, kDefaultMockSchedule.length);
      expect(schedule.first['tournament'], 'WTT Champions Chongqing');
      expect(schedule.first['team_a'], 'Wang Chuqin');
    });

    test('LocalDatabaseService loads schedule from local JSON file', () async {
      final localDb = LocalDatabaseService(
        localJsonPath: 'test/assets/mock_schedule.json',
      );
      await localDb.initialize();

      final schedule = await localDb.fetchTournamentSchedule();
      expect(schedule.length, 3);
      expect(schedule[0]['tournament'], 'WTT Champions Chongqing');
      expect(schedule[2]['tournament'], 'China Smash');
    });

    test('LocalDatabaseService setScheduleData updates data in-memory', () async {
      final localDb = LocalDatabaseService();
      final customRows = [
        {
          'tournament': 'Hermetic Open 2026',
          'year': 2026,
          'team_a': 'Player One',
          'team_b': 'Player Two',
          'upload_date': '2026-07-01T12:00:00Z',
          'youtube_id': 'local_test_vid',
          'is_doubles': false,
          'day': 'Day 1',
        },
      ];

      localDb.setScheduleData(customRows);
      final schedule = await localDb.fetchTournamentSchedule();

      expect(schedule.length, 1);
      expect(schedule.first['tournament'], 'Hermetic Open 2026');
    });

    test('DatabaseService singleton instance is swappable', () {
      expect(DatabaseService.instance, isA<ProdDatabaseService>());

      final localDb = LocalDatabaseService();
      DatabaseService.instance = localDb;
      expect(DatabaseService.instance, isA<LocalDatabaseService>());
    });

    test('FilterController seamlessly fetches data from LocalDatabaseService', () async {
      final localDb = LocalDatabaseService(
        localJsonPath: 'test/assets/mock_schedule.json',
      );
      await localDb.initialize();
      DatabaseService.instance = localDb;

      final controller = FilterController();
      controller.customDataFetcher = null; // Query DatabaseService.instance

      await controller.fetchData();

      expect(controller.isLoading, isFalse);
      expect(controller.allTournaments.length, 2); // WTT Champions Chongqing 2026 & China Smash 2025
      expect(controller.allMatches.length, 3);

      final chongqing = controller.allTournaments.firstWhere((t) => t.name == 'WTT Champions Chongqing');
      expect(chongqing.year, 2026);
      expect(chongqing.type, TournamentType.champions);

      expect(controller.selectedMatch.title, 'Wang Chuqin vs Fan Zhendong');
    });
  });
}
