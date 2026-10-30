import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/user_database_sync_service.dart';
import 'linked_devices_screen.dart';
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

  Widget _buildStatusCard(BuildContext context, SyncStatus status, bool isConnected, DateTime? lastSync) {
    final Color borderColor;
    final Color bgColor;
    final Widget iconWidget;
    final String title;
    final String subtitle;
    final List<Widget> actions;

    switch (status) {
      case SyncStatus.paused:
        borderColor = const Color(0xFFF59E0B);
        bgColor = const Color(0xFF78350F).withValues(alpha: 0.25);
        iconWidget = const Icon(Icons.pause_circle_filled_rounded, size: 40, color: Color(0xFFF59E0B));
        title = 'Supabase Project is Paused (Inactive 7+ Days)';
        subtitle = 'Supabase paused your project due to 7 days of inactivity. All your viewing history is safely preserved! Please click below to open your Supabase dashboard and restore it (~1 minute).';
        final ref = UserDatabaseSyncService.instance.effectiveProjectRef;
        final dashboardUrl = ref != null
            ? 'https://supabase.com/dashboard/project/$ref'
            : 'https://supabase.com/dashboard';
        actions = [
          ElevatedButton.icon(
            onPressed: () {
              launchUrl(Uri.parse(dashboardUrl), mode: LaunchMode.externalApplication);
            },
            icon: const Icon(Icons.open_in_new, size: 15, color: Colors.white),
            label: const Text('Restore in Dashboard', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: dashboardUrl));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('📋 Dashboard restore link copied to clipboard! Paste it into your browser to unpause.'),
                    backgroundColor: Color(0xFFF59E0B),
                    duration: Duration(seconds: 4),
                  ),
                );
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 15, color: Colors.white),
            label: const Text('Copy Link', style: TextStyle(color: Colors.white, fontSize: 13)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFFF59E0B)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () => UserDatabaseSyncService.instance.syncAll(),
            icon: const Icon(Icons.refresh, size: 15, color: Colors.white),
            label: const Text('Check Again', style: TextStyle(color: Colors.white, fontSize: 13)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF94A3B8)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => UserDatabaseSyncService.instance.disconnect(),
            icon: const Icon(Icons.link_off, color: Color(0xFFEF4444)),
            tooltip: 'Disconnect',
          ),
        ];
        break;

      case SyncStatus.error:
        borderColor = const Color(0xFFEF4444);
        bgColor = const Color(0xFF7F1D1D).withValues(alpha: 0.25);
        iconWidget = const Icon(Icons.cloud_off_rounded, size: 40, color: Color(0xFFEF4444));
        title = 'Cloud Sync Connection Error';
        subtitle = 'Unable to connect to your Supabase database. Please check your internet connection or verify your project settings.';
        actions = [
          ElevatedButton.icon(
            onPressed: () => UserDatabaseSyncService.instance.syncAll(),
            icon: const Icon(Icons.sync, size: 15, color: Colors.white),
            label: const Text('Retry Now', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => UserDatabaseSyncService.instance.disconnect(),
            icon: const Icon(Icons.link_off, color: Color(0xFFEF4444)),
            tooltip: 'Disconnect',
          ),
        ];
        break;

      case SyncStatus.syncing:
        borderColor = const Color(0xFF0D7FF2);
        bgColor = const Color(0xFF1E293B);
        iconWidget = const SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFF0D7FF2)),
        );
        title = 'Syncing in Progress...';
        subtitle = 'Reconciling playback progress and settings with your database...';
        actions = [
          ElevatedButton.icon(
            onPressed: null,
            icon: const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
            ),
            label: const Text('Syncing...', style: TextStyle(color: Colors.white70, fontSize: 13)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E3A8A),
              disabledBackgroundColor: const Color(0xFF1E3A8A),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ];
        break;

      case SyncStatus.idle:
        borderColor = const Color(0xFF10B981);
        bgColor = const Color(0xFF1E293B);
        iconWidget = const Icon(Icons.cloud_done_rounded, size: 40, color: Color(0xFF10B981));
        title = 'Connected to Personal Supabase';
        subtitle = lastSync != null
            ? 'Last sync: ${lastSync.toLocal().toString().split('.').first}'
            : 'Connected and ready to sync';
        actions = [
          ElevatedButton.icon(
            onPressed: () => UserDatabaseSyncService.instance.syncAll(),
            icon: const Icon(Icons.sync, size: 16, color: Colors.white),
            label: const Text('Sync Now', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0D7FF2),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LinkedDevicesScreen()),
              );
            },
            icon: const Icon(Icons.devices_rounded, size: 15, color: Colors.white),
            label: const Text('Link Device', style: TextStyle(color: Colors.white, fontSize: 13)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF6366F1)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => UserDatabaseSyncService.instance.disconnect(),
            icon: const Icon(Icons.link_off, color: Color(0xFFEF4444)),
            tooltip: 'Disconnect',
          ),
        ];
        break;

      case SyncStatus.disconnected:
        borderColor = const Color(0xFF334155);
        bgColor = const Color(0xFF1E293B);
        iconWidget = Icon(Icons.cloud_off_rounded, size: 40, color: Colors.grey[500]);
        title = 'Not Connected (Local Only)';
        subtitle = 'Connect your personal free Supabase account to sync match progress across devices.';
        actions = [
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LinkedDevicesScreen()),
              );
            },
            icon: const Icon(Icons.devices_rounded, size: 16, color: Color(0xFF818CF8)),
            label: const Text('Link from Phone or PC (Auto-Setup)', style: TextStyle(color: Color(0xFF818CF8), fontSize: 13, fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF6366F1)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ];
        break;
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              iconWidget,
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
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
                      const SizedBox(height: 6),
                    ],
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 12, color: Color(0xFFCBD5E1), height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildKeepaliveCard(BuildContext context) {
    final isKeepaliveActive = UserDatabaseSyncService.instance.isKeepaliveActive;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isKeepaliveActive
              ? const Color(0xFF10B981).withValues(alpha: 0.4)
              : const Color(0xFFF59E0B).withValues(alpha: 0.4),
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isKeepaliveActive ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                size: 20,
                color: isKeepaliveActive ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Keep-Alive (7-Day Pause Prevention)',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isKeepaliveActive
                      ? const Color(0xFF10B981).withValues(alpha: 0.15)
                      : const Color(0xFFF59E0B).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isKeepaliveActive ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
                    width: 0.8,
                  ),
                ),
                child: Text(
                  isKeepaliveActive ? 'ACTIVE' : 'PENDING REGISTRATION',
                  style: TextStyle(
                    color: isKeepaliveActive ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            isKeepaliveActive
                ? 'Keep-alive is active. Your project is automatically registered with our daily keep-alive service. A background worker sends daily pings via GitHub Actions to reset Supabase\'s 7-day inactivity timer so your database stays awake.'
                : 'Keep-alive automatically registers your project on initial setup or app startup to prevent Supabase 7-day inactivity pauses.',
            style: const TextStyle(fontSize: 12, color: Color(0xFFCBD5E1), height: 1.4),
          ),
          if (!isKeepaliveActive) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () async {
                  final ok = await UserDatabaseSyncService.instance.registerKeepaliveManually();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(ok
                            ? '✅ Keep-alive successfully registered!'
                            : '⚠️ Keep-alive registration failed. Please check connection.'),
                        backgroundColor: ok ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.refresh, size: 14, color: Color(0xFF0D7FF2)),
                label: const Text('Register Keep-Alive Now', style: TextStyle(fontSize: 12, color: Color(0xFF0D7FF2), fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ],
      ),
    );
  }

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
                    // Status Card (State-driven for Paused, Syncing, Error, Idle, and Disconnected)
                    _buildStatusCard(context, status, isConnected, lastSync),

                    if (isConnected) ...[
                      const SizedBox(height: 16),
                      _buildKeepaliveCard(context),
                    ],

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
