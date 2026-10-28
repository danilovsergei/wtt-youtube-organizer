import 'dart:convert';
import 'dart:io';
import 'database_service.dart';
import 'mock_schedule.dart';

class LocalDatabaseService implements DatabaseService {
  final String? localJsonPath;
  List<Map<String, dynamic>> _scheduleData;

  LocalDatabaseService({
    this.localJsonPath,
    List<Map<String, dynamic>>? initialData,
  }) : _scheduleData = initialData ?? kDefaultMockSchedule;

  @override
  Future<void> initialize() async {
    if (localJsonPath != null && File(localJsonPath!).existsSync()) {
      try {
        final content = await File(localJsonPath!).readAsString();
        final decoded = jsonDecode(content);
        if (decoded is List) {
          _scheduleData = decoded.cast<Map<String, dynamic>>();
        }
      } catch (_) {
        // Fall back to default mock data
      }
    }
  }

  void setScheduleData(List<Map<String, dynamic>> data) {
    _scheduleData = data;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTournaments({int limit = 20, int offset = 0}) async {
    final Map<String, Map<String, dynamic>> map = {};
    for (final row in _scheduleData) {
      final t = row['tournament'] as String?;
      final y = row['year'] as int?;
      if (t != null && y != null) {
        final key = '${t}_$y';
        map.putIfAbsent(key, () => {
          'id': key,
          'name': t,
          'year': y,
          'match_count': 0,
        });
        map[key]!['match_count'] = (map[key]!['match_count'] as int) + 1;
      }
    }
    final all = map.values.toList();
    if (offset >= all.length) return [];
    final end = (offset + limit < all.length) ? offset + limit : all.length;
    return all.sublist(offset, end);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTournamentMatches(String tournamentName, int year) async {
    return _scheduleData
        .where((r) => r['tournament'] == tournamentName && r['year'] == year)
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTournamentSchedule() async {
    return List<Map<String, dynamic>>.from(_scheduleData);
  }
}
