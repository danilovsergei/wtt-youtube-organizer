import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/user_database_sync_service.dart';
import '../services/supabase_management_service.dart';

class CloudSyncScreen extends StatefulWidget {
  const CloudSyncScreen({super.key});

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _keyController = TextEditingController();

  bool _isProvisioning = false;
  String _provisioningStep = '';
  String? _errorMessage;
  bool _showManualSetup = false;

  @override
  void dispose() {
    _tokenController.dispose();
    _urlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _handleOAuthLogin({bool autoLaunch = true}) async {
    setState(() {
      _isProvisioning = true;
      _errorMessage = null;
      _provisioningStep = autoLaunch
          ? 'Starting browser SSO...'
          : 'Link copied! Waiting for authorization in your browser...';
    });

    try {
      final token = await SupabaseManagementService.authenticateViaBrowserOAuth(
        autoLaunchBrowser: autoLaunch,
        onProgress: (step) {
          if (mounted) {
            setState(() => _provisioningStep = step);
          }
        },
      );

      final config = await SupabaseManagementService.provisionAndSetupProject(
        accessToken: token,
        onProgress: (step) {
          if (mounted) {
            setState(() => _provisioningStep = step);
          }
        },
      );

      await UserDatabaseSyncService.instance.connectWithCredentials(
        projectUrl: config['url']!,
        anonKey: config['anon_key']!,
        projectRef: config['project_ref'],
      );

      if (mounted) {
        setState(() => _isProvisioning = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('🎉 Connected to personal Supabase database successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProvisioning = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _handleCopyOAuthLink() async {
    final url = SupabaseManagementService.getOAuthAuthorizationUrl();
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('📋 Link copied to clipboard! Paste it into your private browser tab to authorize.'),
          backgroundColor: Color(0xFF0D7FF2),
          duration: Duration(seconds: 4),
        ),
      );
    }
    // Automatically start listener so it waits for the code from the private window
    _handleOAuthLogin(autoLaunch: false);
  }

  Future<void> _handleAutoSetup() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _errorMessage = 'Please enter your Supabase Access Token (sbp_...)');
      return;
    }

    setState(() {
      _isProvisioning = true;
      _errorMessage = null;
      _provisioningStep = 'Starting project setup...';
    });

    try {
      final config = await SupabaseManagementService.provisionAndSetupProject(
        accessToken: token,
        onProgress: (step) {
          if (mounted) {
            setState(() => _provisioningStep = step);
          }
        },
      );

      await UserDatabaseSyncService.instance.connectWithCredentials(
        projectUrl: config['url']!,
        anonKey: config['anon_key']!,
        projectRef: config['project_ref'],
      );

      if (mounted) {
        setState(() {
          _isProvisioning = false;
          _tokenController.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('🎉 Connected to personal Supabase database successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProvisioning = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _handleManualConnect() async {
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();

    if (url.isEmpty || key.isEmpty) {
      setState(() => _errorMessage = 'Both Project URL and Anon Key are required');
      return;
    }

    setState(() {
      _isProvisioning = true;
      _errorMessage = null;
    });

    try {
      await UserDatabaseSyncService.instance.connectWithCredentials(
        projectUrl: url,
        anonKey: key,
      );

      if (mounted) {
        setState(() {
          _isProvisioning = false;
          _urlController.clear();
          _keyController.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connected to Supabase successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProvisioning = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: const Text('Cloud Sync (Supabase)'),
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
      ),
      body: ListenableBuilder(
        listenable: UserDatabaseSyncService.instance,
        builder: (context, _) {
          final isConnected = UserDatabaseSyncService.instance.isConnected;
          final status = UserDatabaseSyncService.instance.status;
          final lastSync = UserDatabaseSyncService.instance.lastSyncTime;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Status Card
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isConnected ? const Color(0xFF10B981) : const Color(0xFF334155),
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isConnected ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                            size: 40,
                            color: isConnected ? const Color(0xFF10B981) : Colors.grey[500],
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isConnected ? 'Connected to Personal Supabase' : 'Not Connected (Local Only)',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                if (isConnected) ...[
                                  Text(
                                    UserDatabaseSyncService.instance.projectUrl ?? '',
                                    style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    lastSync != null
                                        ? 'Last sync: ${lastSync.toLocal().toString().split('.').first}'
                                        : 'Syncing in progress...',
                                    style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                                  ),
                                ] else ...[
                                  const Text(
                                    'Connect your personal free Supabase account to sync match progress across devices.',
                                    style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (isConnected) ...[
                            ElevatedButton.icon(
                              onPressed: status == SyncStatus.syncing
                                  ? null
                                  : () => UserDatabaseSyncService.instance.syncAll(),
                              icon: status == SyncStatus.syncing
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Icon(Icons.sync, size: 16, color: Colors.white),
                              label: const Text(
                                'Sync Now',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0D7FF2),
                                foregroundColor: Colors.white,
                                disabledBackgroundColor: const Color(0xFF1E3A8A),
                                disabledForegroundColor: Colors.white70,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: () => UserDatabaseSyncService.instance.disconnect(),
                              icon: const Icon(Icons.link_off, color: Color(0xFFEF4444)),
                              tooltip: 'Disconnect',
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    if (_errorMessage != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEF4444).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFEF4444)),
                        ),
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    if (_isProvisioning) ...[
                      Container(
                        padding: const EdgeInsets.all(28),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.4)),
                        ),
                        child: Column(
                          children: [
                            const CircularProgressIndicator(color: Color(0xFF10B981)),
                            const SizedBox(height: 20),
                            Text(
                              _provisioningStep,
                              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ] else if (!isConnected) ...[
                      // 1-Click SSO Card (Primary Action)
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF10B981), width: 1.5),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF10B981).withValues(alpha: 0.15),
                              blurRadius: 16,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.bolt_rounded, color: Color(0xFF10B981), size: 24),
                                SizedBox(width: 10),
                                Text(
                                  '1-Click Sign in with Supabase (SSO)',
                                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Click below to open your browser and sign in with Google or GitHub. The app will automatically connect and provision your personal free database.',
                              style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, height: 1.4),
                            ),
                            const SizedBox(height: 20),
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () => _handleOAuthLogin(autoLaunch: true),
                                    icon: const Icon(Icons.open_in_browser_rounded, size: 20),
                                    label: const Text(
                                      'Sign in in Browser',
                                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF10B981),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 16),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                ElevatedButton.icon(
                                  onPressed: _handleCopyOAuthLink,
                                  icon: const Icon(Icons.copy_rounded, size: 18),
                                  label: const Text('Copy Link'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF0F172A),
                                    foregroundColor: const Color(0xFF38BDF8),
                                    side: const BorderSide(color: Color(0xFF38BDF8), width: 1.2),
                                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),

                      // Manual Options Accordion
                      TextButton.icon(
                        onPressed: () => setState(() => _showManualSetup = !_showManualSetup),
                        icon: Icon(_showManualSetup ? Icons.expand_less : Icons.expand_more, size: 18),
                        label: Text(_showManualSetup ? 'Hide Alternative Login Options' : 'Alternative: Personal Access Token or Custom URL'),
                        style: TextButton.styleFrom(foregroundColor: const Color(0xFF38BDF8)),
                      ),

                      if (_showManualSetup) ...[
                        const SizedBox(height: 8),
                        // Personal Access Token Setup Card
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Personal Access Token',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Generate at: supabase.com/dashboard/account/tokens',
                                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _tokenController,
                                obscureText: true,
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                                decoration: InputDecoration(
                                  labelText: 'Token (sbp_...)',
                                  filled: true,
                                  fillColor: const Color(0xFF0F172A),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: _handleAutoSetup,
                                  icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                                  label: const Text('Provision using Token'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF334155),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 12),

                        // Custom URL & Key Setup Card
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Existing Project URL & Anon Key',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _urlController,
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                                decoration: InputDecoration(
                                  labelText: 'Supabase Project URL',
                                  hintText: 'https://xxxxxxxx.supabase.co',
                                  filled: true,
                                  fillColor: const Color(0xFF0F172A),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _keyController,
                                obscureText: true,
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                                decoration: InputDecoration(
                                  labelText: 'Supabase Anon Key',
                                  filled: true,
                                  fillColor: const Color(0xFF0F172A),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: _handleManualConnect,
                                  icon: const Icon(Icons.link, size: 16),
                                  label: const Text('Connect with URL & Key'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF334155),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
