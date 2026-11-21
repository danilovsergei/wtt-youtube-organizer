import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/prod_database.dart';
import '../video/ytdlp/stream_policy.dart';
import 'log_service.dart';

class StreamPolicyService {
  static final StreamPolicyService instance = StreamPolicyService._();
  StreamPolicyService._();

  static const String _prefsKey = 'cached_stream_policy_json';
  StreamPolicy _activePolicy = const StreamPolicy();

  StreamPolicy get activePolicy => _activePolicy;

  /// Initializes policy: bundled asset -> cached SharedPreferences -> background Supabase fetch.
  Future<void> initialize() async {
    // 1. Load bundled default asset first (instant)
    try {
      final assetStr = await rootBundle.loadString('assets/default_stream_policy.json');
      final assetJson = jsonDecode(assetStr) as Map<String, dynamic>;
      _activePolicy = StreamPolicy.fromJson(assetJson);
      LogService.instance.log('[POLICY] Loaded bundled default stream policy (v${_activePolicy.version})');
    } catch (e) {
      LogService.instance.log('[POLICY] Warning loading bundled policy: $e');
    }

    // 2. Check local SharedPreferences cache
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedJsonStr = prefs.getString(_prefsKey);
      if (cachedJsonStr != null && cachedJsonStr.isNotEmpty) {
        final cachedJson = jsonDecode(cachedJsonStr) as Map<String, dynamic>;
        _activePolicy = StreamPolicy.fromJson(cachedJson);
        LogService.instance.log('[POLICY] Loaded cached stream policy from storage (v${_activePolicy.version})');
      }
    } catch (e) {
      LogService.instance.log('[POLICY] Warning reading cached policy: $e');
    }

    // 3. Fetch fresh policy from Supabase in background
    fetchFreshPolicyFromSupabase();
  }

  /// Fetches the latest stream policy from Supabase and updates local storage.
  Future<bool> fetchFreshPolicyFromSupabase() async {
    try {
      final client = ProdDatabaseService().client;
      final res = await client
          .from('app_stream_policies')
          .select('policy_data')
          .eq('policy_name', 'default')
          .maybeSingle();

      if (res != null && res['policy_data'] != null) {
        final policyMap = res['policy_data'] as Map<String, dynamic>;
        _activePolicy = StreamPolicy.fromJson(policyMap);
        LogService.instance.log(
          '[POLICY] Successfully updated stream policy from Supabase (v${_activePolicy.version}, blockedItags: ${_activePolicy.blockedItags})',
        );

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsKey, jsonEncode(policyMap));
        return true;
      }
    } catch (e) {
      LogService.instance.log('[POLICY] Supabase policy fetch warning (using cached/bundled): $e');
    }
    return false;
  }

  @visibleForTesting
  void setActivePolicyForTest(StreamPolicy policy) {
    _activePolicy = policy;
  }
}
