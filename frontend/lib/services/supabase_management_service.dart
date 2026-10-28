import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'log_service.dart';

class SupabaseManagementService {
  static const String apiBase = 'https://api.supabase.com/v1';

  static const String oauthClientId = String.fromEnvironment(
    'SUPABASE_OAUTH_CLIENT_ID',
    defaultValue: 'a4db211c-460f-4b7a-916b-73ee522da633',
  );

  static const String oauthClientSecret = String.fromEnvironment(
    'SUPABASE_OAUTH_CLIENT_SECRET',
  );

  static String generateDbPassword() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#%^*';
    final random = Random.secure();
    return List.generate(20, (index) => chars[random.nextInt(chars.length)]).join();
  }

  /// Returns the complete Supabase OAuth authorization URL for manual or private browser use.
  static String getOAuthAuthorizationUrl() {
    const port = 45821;
    const redirectUri = 'http://localhost:$port/callback';
    return Uri.parse('$apiBase/oauth/authorize').replace(
      queryParameters: {
        'client_id': oauthClientId,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'scope': 'all',
      },
    ).toString();
  }

  /// Launches the system browser to the Supabase SSO OAuth page and captures the authorization code via loopback server.
  static Future<String> authenticateViaBrowserOAuth({
    void Function(String step)? onProgress,
    bool autoLaunchBrowser = true,
  }) async {
    const port = 45821;
    const redirectUri = 'http://localhost:$port/callback';

    onProgress?.call('Starting local authentication listener...');
    LogService.instance.log('[OAUTH] Binding loopback listener on port $port...');

    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } catch (e) {
      throw Exception('Could not start local authorization listener on port $port: $e');
    }

    final authUri = Uri.parse('$apiBase/oauth/authorize').replace(
      queryParameters: {
        'client_id': oauthClientId,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'scope': 'all',
      },
    );

    final codeCompleter = Completer<String>();

    server.listen((HttpRequest request) async {
      if (request.uri.path == '/callback') {
        final code = request.uri.queryParameters['code'];
        final error = request.uri.queryParameters['error'];
        final errorDesc = request.uri.queryParameters['error_description'];

        request.response.headers.contentType = ContentType.html;
        if (code != null && code.isNotEmpty) {
          request.response.write('''
            <!DOCTYPE html>
            <html>
            <head><meta charset="utf-8"><title>Supabase Connected</title></head>
            <body style="background:#0F172A;color:white;font-family:system-ui,-apple-system,sans-serif;display:flex;align-items:center;justify-content:center;height:90vh;margin:0;">
              <div style="background:#1E293B;padding:40px;border-radius:16px;text-align:center;box-shadow:0 10px 25px rgba(0,0,0,0.5);border:1.5px solid #10B981;max-width:440px;">
                <h1 style="color:#10B981;margin-bottom:12px;font-size:28px;">🎉 Connected!</h1>
                <p style="color:#CBD5E1;font-size:16px;line-height:1.5;">Your Supabase account has been authorized successfully.</p>
                <p style="color:#94A3B8;font-size:13px;margin-top:24px;">You can now close this tab and return to <strong>WTT Organizer</strong>.</p>
              </div>
            </body>
            </html>
          ''');
          await request.response.close();
          if (!codeCompleter.isCompleted) {
            codeCompleter.complete(code);
          }
        } else {
          final errMsg = errorDesc ?? error ?? 'OAuth authorization failed';
          request.response.write('<html><body><h3>Authentication failed: $errMsg</h3></body></html>');
          await request.response.close();
          if (!codeCompleter.isCompleted) {
            codeCompleter.completeError(Exception(errMsg));
          }
        }
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    });

    if (autoLaunchBrowser) {
      onProgress?.call('Opening Supabase SSO in your browser...');
      LogService.instance.log('[OAUTH] Opening browser to: $authUri');

      try {
        final launched = await launchUrl(
          authUri,
          mode: LaunchMode.externalApplication,
        );
        if (!launched) {
          await Process.run('gio', ['open', authUri.toString()]);
        }
      } catch (e) {
        LogService.instance.log('[OAUTH] launchUrl error: $e, trying gio open...');
        try {
          await Process.run('gio', ['open', authUri.toString()]);
        } catch (_) {
          LogService.instance.log('[OAUTH] Please open this URL in your browser: $authUri');
        }
      }
    } else {
      onProgress?.call('Waiting for authorization from browser tab...');
      LogService.instance.log('[OAUTH] Waiting for authorization callback from manual/private browser tab...');
    }

    final String code;
    try {
      code = await codeCompleter.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw TimeoutException('Authentication timed out after 5 minutes'),
      );
    } finally {
      await server.close(force: true);
    }

    onProgress?.call('Exchanging authorization code for access token...');
    LogService.instance.log('[OAUTH] Exchanging code for access token...');

    if (oauthClientSecret.isEmpty) {
      throw Exception(
        'SUPABASE_OAUTH_CLIENT_SECRET is not configured in build. Please provide a Personal Access Token instead.',
      );
    }

    final tokenResp = await http.post(
      Uri.parse('$apiBase/oauth/token'),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': oauthClientId,
        'client_secret': oauthClientSecret,
        'redirect_uri': redirectUri,
      },
    );

    if (tokenResp.statusCode != 200) {
      throw Exception('OAuth token exchange failed (${tokenResp.statusCode}): ${tokenResp.body}');
    }

    final tokenData = jsonDecode(tokenResp.body) as Map<String, dynamic>;
    final accessToken = tokenData['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw Exception('No access_token found in token response: ${tokenResp.body}');
    }

    LogService.instance.log('[OAUTH] Token exchange successful!');
    return accessToken;
  }

  /// Automatically provisions the 'wtt-organizer' project, runs migrations, and returns { url, anon_key, project_ref }
  static Future<Map<String, String>> provisionAndSetupProject({
    required String accessToken,
    void Function(String step)? onProgress,
  }) async {
    onProgress?.call('Fetching organizations...');
    LogService.instance.log('[PROVISION] Fetching organizations...');

    // 1. Get organizations
    final orgResp = await http.get(
      Uri.parse('$apiBase/organizations'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (orgResp.statusCode != 200) {
      throw Exception('Failed to fetch organizations (${orgResp.statusCode}): ${orgResp.body}');
    }
    final orgs = (jsonDecode(orgResp.body) as List<dynamic>).cast<Map<String, dynamic>>();
    String orgId;
    if (orgs.isEmpty) {
      onProgress?.call('Creating organization "WTT Organizer" via API...');
      LogService.instance.log('[PROVISION] Creating organization via API...');
      final createOrgResp = await http.post(
        Uri.parse('$apiBase/organizations'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'name': 'WTT Organizer'}),
      );
      if (createOrgResp.statusCode != 201 && createOrgResp.statusCode != 200) {
        throw Exception('Failed to create organization via API (${createOrgResp.statusCode}): ${createOrgResp.body}');
      }
      final createdOrg = jsonDecode(createOrgResp.body) as Map<String, dynamic>;
      orgId = createdOrg['id'] as String;
      LogService.instance.log('[PROVISION] Created organization $orgId via API');
    } else {
      orgId = orgs.first['id'] as String;
      LogService.instance.log('[PROVISION] Using organization $orgId');
    }

    // 2. Check if project already exists
    onProgress?.call('Checking existing projects...');
    LogService.instance.log('[PROVISION] Checking existing projects in organization $orgId...');
    final projResp = await http.get(
      Uri.parse('$apiBase/projects'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (projResp.statusCode != 200) {
      throw Exception('Failed to fetch projects (${projResp.statusCode}): ${projResp.body}');
    }
    final projects = (jsonDecode(projResp.body) as List<dynamic>).cast<Map<String, dynamic>>();

    Map<String, dynamic>? existingProject;
    for (final p in projects) {
      if (p['name'] == 'wtt-organizer') {
        existingProject = p;
        break;
      }
    }

    String projectRef;
    if (existingProject != null) {
      projectRef = existingProject['id'] as String;
      LogService.instance.log('[PROVISION] Found existing project: $projectRef');
    } else {
      // 3. Create project
      onProgress?.call('Creating new project "wtt-organizer"...');
      LogService.instance.log('[PROVISION] Creating new project "wtt-organizer"...');
      final dbPass = generateDbPassword();
      final createResp = await http.post(
        Uri.parse('$apiBase/projects'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'name': 'wtt-organizer',
          'organization_id': orgId,
          'plan': 'free',
          'region': 'us-east-1',
          'db_pass': dbPass,
        }),
      );
      if (createResp.statusCode != 201 && createResp.statusCode != 200) {
        throw Exception('Failed to create project (${createResp.statusCode}): ${createResp.body}');
      }
      final created = jsonDecode(createResp.body) as Map<String, dynamic>;
      projectRef = created['id'] as String;
      LogService.instance.log('[PROVISION] Project creation initiated with ref: $projectRef');
    }

    // 4. Wait for project to be ACTIVE_HEALTHY
    onProgress?.call('Waiting for database to be ready...');
    int attempts = 0;
    while (attempts < 60) {
      final statusResp = await http.get(
        Uri.parse('$apiBase/projects/$projectRef/status'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (statusResp.statusCode == 200) {
        final statusData = jsonDecode(statusResp.body) as Map<String, dynamic>;
        final status = statusData['status']?.toString();
        LogService.instance.log('[PROVISION] Project status: $status');
        if (status == 'ACTIVE_HEALTHY') {
          break;
        }
      }
      attempts++;
      await Future.delayed(const Duration(seconds: 4));
    }

    // 5. Run SQL Migration
    onProgress?.call('Setting up database tables and permissions...');
    LogService.instance.log('[PROVISION] Running SQL migration...');
    const migrationSql = '''
    create table if not exists public.playback_progress (
        match_id text primary key,
        youtube_id text,
        position_seconds integer not null,
        default_offset_seconds integer not null default 0,
        duration_seconds integer,
        updated_at timestamptz not null default now()
    );
    alter table public.playback_progress enable row level security;
    do \$\$ begin
      if not exists (select 1 from pg_policies where tablename = 'playback_progress' and policyname = 'Allow anon progress') then
        create policy "Allow anon progress" on public.playback_progress for all using (true) with check (true);
      end if;
    end \$\$;

    create table if not exists public.user_settings (
        key text primary key,
        value jsonb not null,
        updated_at timestamptz not null default now()
    );
    alter table public.user_settings enable row level security;
    do \$\$ begin
      if not exists (select 1 from pg_policies where tablename = 'user_settings' and policyname = 'Allow anon settings') then
        create policy "Allow anon settings" on public.user_settings for all using (true) with check (true);
      end if;
    end \$\$;
    ''';

    final queryResp = await http.post(
      Uri.parse('$apiBase/projects/$projectRef/database/query'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'query': migrationSql}),
    );
    LogService.instance.log('[PROVISION] Migration response (${queryResp.statusCode})');

    // 6. Get API keys
    onProgress?.call('Retrieving project API keys...');
    LogService.instance.log('[PROVISION] Retrieving project API keys...');
    final keysResp = await http.get(
      Uri.parse('$apiBase/projects/$projectRef/api-keys'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (keysResp.statusCode != 200) {
      throw Exception('Failed to get API keys (${keysResp.statusCode}): ${keysResp.body}');
    }
    final keysList = (jsonDecode(keysResp.body) as List<dynamic>).cast<Map<String, dynamic>>();
    final anonKeyEntry = keysList.firstWhere(
      (k) => k['name'] == 'anon' || k['tags']?.toString().contains('anon') == true,
      orElse: () => keysList.first,
    );
    final anonKey = anonKeyEntry['api_key'] as String;
    final projectUrl = 'https://$projectRef.supabase.co';

    LogService.instance.log('[PROVISION] Successfully set up user Supabase project: $projectUrl');
    return {
      'url': projectUrl,
      'anon_key': anonKey,
      'project_ref': projectRef,
    };
  }
}
