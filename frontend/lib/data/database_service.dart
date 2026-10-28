import 'prod_database.dart';

abstract class DatabaseService {
  /// Connects to the database / initializes client.
  Future<void> initialize();

  /// Fetches tournament titles with pagination.
  Future<List<Map<String, dynamic>>> fetchTournaments({int limit = 20, int offset = 0});

  /// Fetches matches for a specific tournament.
  Future<List<Map<String, dynamic>>> fetchTournamentMatches(String tournamentName, int year);

  /// Bulk fetch (for backwards compatibility and legacy test runners).
  Future<List<Map<String, dynamic>>> fetchTournamentSchedule();

  /// Active singleton/service instance.
  static DatabaseService instance = ProdDatabaseService();
}
