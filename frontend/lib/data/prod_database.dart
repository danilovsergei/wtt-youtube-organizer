import 'package:supabase_flutter/supabase_flutter.dart';
import 'database_service.dart';

class ProdDatabaseService implements DatabaseService {
  static const String supabaseUrl = 'https://yxegxufjztnsogjrqsqw.supabase.co';
  static const String supabaseAnonKey = 'sb_publishable_YLN9F1xMInlM8BbwF_dA3Q_rBU9V687';

  bool _isInitialized = false;

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      await Supabase.initialize(
        url: supabaseUrl,
        anonKey: supabaseAnonKey,
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
    final List<dynamic> response = await Supabase.instance.client
        .from('v_tournament_schedule')
        .select()
        .order('upload_date', ascending: false);

    return response.cast<Map<String, dynamic>>();
  }
}
