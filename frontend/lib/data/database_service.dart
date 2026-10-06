import 'prod_database.dart';

abstract class DatabaseService {
  /// Connects to the database / loads cache.
  Future<void> initialize();

  /// Fetches the raw schedule records matching view `v_tournament_schedule`.
  Future<List<Map<String, dynamic>>> fetchTournamentSchedule();

  /// Active singleton/service instance.
  /// Defaults to [ProdDatabaseService], but can be swapped with [LocalDatabaseService]
  /// for offline / hermetic execution and tests.
  static DatabaseService instance = ProdDatabaseService();
}
