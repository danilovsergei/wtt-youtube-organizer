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

  final String? _customUrl;
  final String? _customKey;
  SupabaseClient? _client;

  ProdDatabaseService({String? customUrl, String? customKey})
      : _customUrl = customUrl,
        _customKey = customKey;

  SupabaseClient get client {
    if (_client != null) return _client!;
    if (_customUrl != null && _customKey != null) {
      _client = SupabaseClient(_customUrl, _customKey);
      return _client!;
    }
    return Supabase.instance.client;
  }

  bool _isInitialized = false;

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;
    if (_customUrl != null && _customKey != null) {
      _client = SupabaseClient(_customUrl, _customKey);
      _isInitialized = true;
      return;
    }
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
  Future<List<Map<String, dynamic>>> fetchTournaments({int limit = 20, int offset = 0}) async {
    if (!_isInitialized) {
      await initialize();
    }
    final List<dynamic> response = await client
        .from('v_tournaments')
        .select()
        .order('last_upload', ascending: false)
        .range(offset, offset + limit - 1);

    return response.cast<Map<String, dynamic>>();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTournamentMatches(String tournamentName, int year) async {
    if (!_isInitialized) {
      await initialize();
    }
    final List<dynamic> response = await client
        .from('v_tournament_schedule')
        .select()
        .eq('tournament', tournamentName)
        .eq('year', year)
        .order('upload_date', ascending: false);

    return response.cast<Map<String, dynamic>>();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTournamentSchedule() async {
    if (!_isInitialized) {
      await initialize();
    }
    const int pageSize = 1000;

    final PostgrestResponse firstResponse = await client
        .from('v_tournament_schedule')
        .select()
        .order('upload_date', ascending: false)
        .range(0, pageSize - 1)
        .count(CountOption.exact);

    final List<dynamic> firstBatch = (firstResponse.data as List<dynamic>?) ?? [];
    final List<Map<String, dynamic>> allRows = [
      ...firstBatch.cast<Map<String, dynamic>>(),
    ];

    final int totalCount = firstResponse.count;
    if (totalCount <= pageSize) {
      return allRows;
    }

    final List<Future<List<dynamic>>> parallelRequests = [];
    for (int from = pageSize; from < totalCount; from += pageSize) {
      final to = from + pageSize - 1;
      parallelRequests.add(
        client
            .from('v_tournament_schedule')
            .select()
            .order('upload_date', ascending: false)
            .range(from, to)
            .then((data) => data as List<dynamic>),
      );
    }

    final results = await Future.wait(parallelRequests);
    for (final batch in results) {
      allRows.addAll(batch.cast<Map<String, dynamic>>());
    }

    return allRows;
  }
}
