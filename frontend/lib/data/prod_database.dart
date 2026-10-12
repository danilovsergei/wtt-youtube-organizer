import 'package:supabase_flutter/supabase_flutter.dart';
import 'database_service.dart';

class ProdDatabaseService implements DatabaseService {
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://yxegxufjztnsogjrqsqw.supabase.co',
  );
  static const String supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: String.fromEnvironment(
      'SUPABASE_ANON_KEY',
      defaultValue: 'sb_publishable_YLN9F1xMInlM8BbwF_dA3Q_rBU9V687',
    ),
  );

  bool _isInitialized = false;

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      await Supabase.initialize(
        url: supabaseUrl,
        publishableKey: supabasePublishableKey,
      );
      _isInitialized = true;
    } catch (_) {
      _isInitialized = true;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTournamentSchedule() async {
    if (!_isInitialized) {
      await initialize();
    }
    final List<Map<String, dynamic>> allRows = [];
    const int pageSize = 1000;
    int from = 0;

    while (true) {
      final List<dynamic> batch = await Supabase.instance.client
          .from('v_tournament_schedule')
          .select()
          .order('upload_date', ascending: false)
          .range(from, from + pageSize - 1);

      allRows.addAll(batch.cast<Map<String, dynamic>>());
      if (batch.length < pageSize) {
        break;
      }
      from += pageSize;
    }

    return allRows;
  }
}
