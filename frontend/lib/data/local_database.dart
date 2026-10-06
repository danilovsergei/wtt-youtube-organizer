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
  }) : _scheduleData = initialData ?? List<Map<String, dynamic>>.from(kDefaultMockSchedule);

  /// Sets custom mock schedule data in memory at runtime.
  void setScheduleData(List<Map<String, dynamic>> data) {
    _scheduleData = List<Map<String, dynamic>>.from(data);
  }

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

  @override
  Future<List<Map<String, dynamic>>> fetchTournamentSchedule() async {
    // Return copy of local in-memory data
    return List<Map<String, dynamic>>.from(_scheduleData);
  }
}
