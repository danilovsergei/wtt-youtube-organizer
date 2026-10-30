import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/device_pairing_service.dart';
import '../services/user_database_sync_service.dart';
import '../services/settings_service.dart';
import 'tv_focusable.dart';

class LinkedDevicesScreen extends StatefulWidget {
  const LinkedDevicesScreen({super.key});

  @override
  State<LinkedDevicesScreen> createState() => _LinkedDevicesScreenState();
}

class _LinkedDevicesScreenState extends State<LinkedDevicesScreen> {
  @visibleForTesting
  static Duration testPollInterval = const Duration(seconds: 2);

  // Linked devices list
  List<Map<String, dynamic>> _linkedDevices = [];
  bool _isLoadingDevices = true;

  // Facilitating mode state (Phone / PC)
  final TextEditingController _codeController = TextEditingController();
  bool _isCheckingCode = false;
  PairingInfo? _foundPairingInfo;
  String? _pairingErrorMessage;
  bool _isFulfilling = false;
  bool _shareCloudSync = true;

  // Receiving mode state (Android TV)
  PairingSession? _activeSession;
  bool _isCreatingSession = false;
  String? _receiveErrorMessage;
  Timer? _countdownTimer;
  int _secondsRemaining = 0;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    final devices = await SettingsService.instance.loadLinkedDevices();
    if (!mounted) return;
    setState(() {
      _linkedDevices = devices;
      _isLoadingDevices = false;
    });
  }

  Future<void> _handleUnlinkDevice(String deviceName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Unlink Device?', style: TextStyle(color: Colors.white, fontSize: 17)),
        content: Text(
          'Are you sure you want to unlink "$deviceName"?',
          style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
            ),
            child: const Text('Unlink'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await SettingsService.instance.removeLinkedDevice(deviceName);
      await _loadDevices();
    }
  }

  // --- Receiving Mode (e.g. on Android TV) ---

  Future<void> _startReceivingSession() async {
    setState(() {
      _isCreatingSession = true;
      _receiveErrorMessage = null;
    });

    final session = await DevicePairingService.instance.createPairingSession();
    if (!mounted) return;

    if (session == null) {
      setState(() {
        _isCreatingSession = false;
        _receiveErrorMessage = 'Failed to generate pairing code. Please check your internet connection.';
      });
      return;
    }

    setState(() {
      _isCreatingSession = false;
      _activeSession = session;
      _secondsRemaining = session.expiresAt.difference(DateTime.now()).inSeconds;
    });

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final remaining = session.expiresAt.difference(DateTime.now()).inSeconds;
      if (remaining <= 0) {
        timer.cancel();
        setState(() {
          _secondsRemaining = 0;
          _receiveErrorMessage = 'Pairing code expired. Please generate a new code.';
        });
      } else {
        setState(() {
          _secondsRemaining = remaining;
        });
      }
    });

    _pollForIncomingCredentials(session);
  }

  Future<void> _pollForIncomingCredentials(PairingSession session) async {
    final payload = await DevicePairingService.instance.pollForClaim(
      session,
      interval: testPollInterval,
    );
    if (!mounted) return;

    if (payload != null && payload['action'] == 'cloud_sync') {
      _countdownTimer?.cancel();
      setState(() {
        _activeSession = null;
      });

      // Adopt Cloud Sync credentials immediately
      final projectUrl = payload['project_url'] as String?;
      final anonKey = payload['anon_key'] as String?;
      final projectRef = payload['project_ref'] as String?;
      final sourceDevice = payload['source_device'] as String? ?? 'Facilitating Device';

      if (projectUrl != null && anonKey != null) {
        await UserDatabaseSyncService.instance.connectWithCredentials(
          projectUrl: projectUrl,
          anonKey: anonKey,
          projectRef: projectRef,
        );
      }

      // Record linked device in settings
      await SettingsService.instance.saveLinkedDevice(
        name: sourceDevice,
        role: 'facilitator',
        status: 'Active',
      );
      await _loadDevices();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Linked with "$sourceDevice"! Cloud Sync is now active.'),
            backgroundColor: const Color(0xFF10B981),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  // --- Facilitating Mode (e.g. on Phone / Desktop) ---

  Future<void> _handleCheckCode(String rawCode) async {
    final cleanCode = rawCode.replaceAll(RegExp(r'\D'), '');
    if (cleanCode.length != 6) return;

    setState(() {
      _isCheckingCode = true;
      _pairingErrorMessage = null;
      _foundPairingInfo = null;
    });

    final info = await DevicePairingService.instance.getPairingInfo(cleanCode);
    if (!mounted) return;

    setState(() {
      _isCheckingCode = false;
      if (info.isValid) {
        _foundPairingInfo = info;
      } else {
        _pairingErrorMessage = info.error ?? 'No active device found with code "$cleanCode".';
      }
    });
  }

  Future<void> _handleConfirmPairing() async {
    if (_foundPairingInfo == null) return;
    final code = _codeController.text.trim();
    final targetDeviceName = _foundPairingInfo?.deviceName ?? 'Android TV';

    setState(() {
      _isFulfilling = true;
      _pairingErrorMessage = null;
    });

    final syncService = UserDatabaseSyncService.instance;
    final Map<String, dynamic> payload = {
      'action': 'cloud_sync',
      'source_device': DevicePairingService.instance.defaultDeviceName,
      'project_url': syncService.projectUrl,
      'anon_key': syncService.anonKey,
      'project_ref': syncService.effectiveProjectRef,
    };

    final ok = await DevicePairingService.instance.fulfillPairing(code, payload);
    if (!mounted) return;

    setState(() {
      _isFulfilling = false;
    });

    if (ok) {
      _codeController.clear();
      setState(() {
        _foundPairingInfo = null;
      });

      // Save target device in facilitating device settings
      await SettingsService.instance.saveLinkedDevice(
        name: targetDeviceName,
        role: 'controlled',
        status: 'Active',
      );
      await _loadDevices();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Successfully linked with "$targetDeviceName"!'),
            backgroundColor: const Color(0xFF10B981),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } else {
      setState(() {
        _pairingErrorMessage = 'Failed to link device. The code may have expired.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTv = DevicePairingService.isTvMode(context);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: const Text('Linked Devices', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header Banner
                const Text(
                  'Device Linking',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  isTv
                      ? 'Link this TV with your phone or computer to sync watch history automatically.'
                      : 'Link your TV, phone, or computer together. Transfer Cloud Sync credentials with 1 tap, and enable remote control.',
                  style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8), height: 1.4),
                ),
                const SizedBox(height: 24),

                // SECTION 1: Active Linked Devices List (Always shown if devices exist)
                _buildLinkedDevicesList(context),

                // SECTION 2: On Android TV -> ONLY show "Show Pairing Code" (controlled target)
                if (isTv) ...[
                  const SizedBox(height: 20),
                  _buildReceivingCard(context, autoStartPrompt: true),
                ] else ...[
                  // On Phone / Desktop -> Show Facilitating Code Entry Form
                  const SizedBox(height: 20),
                  _buildFacilitatingCard(context),
                  const SizedBox(height: 24),
                  _buildReceivingCard(context, autoStartPrompt: false),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLinkedDevicesList(BuildContext context) {
    if (_isLoadingDevices) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_linkedDevices.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B).withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: const Row(
          children: [
            Icon(Icons.devices_other_rounded, color: Color(0xFF94A3B8), size: 28),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'No Devices Linked Yet',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Generate a pairing code on TV or link from your phone below to connect.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.link_rounded, color: Color(0xFF10B981), size: 18),
            const SizedBox(width: 8),
            const Text(
              'LINKED DEVICES',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
                color: Color(0xFF94A3B8),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${_linkedDevices.length}',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _linkedDevices.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final dev = _linkedDevices[index];
            final name = dev['name'] as String? ?? 'Device';
            final linkedAt = dev['linked_at'] as String?;

            DateTime? parsedDate;
            if (linkedAt != null) {
              parsedDate = DateTime.tryParse(linkedAt);
            }

            final IconData deviceIcon = name.toLowerCase().contains('tv')
                ? Icons.tv_rounded
                : (name.toLowerCase().contains('phone') || name.toLowerCase().contains('pixel') || name.toLowerCase().contains('android')
                    ? Icons.smartphone_rounded
                    : Icons.laptop_rounded);

            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF334155), width: 1.2),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                    ),
                    child: Icon(deviceIcon, color: const Color(0xFF818CF8), size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          parsedDate != null
                              ? 'Linked on ${parsedDate.toLocal().toString().split('.').first}'
                              : 'Linked device',
                          style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => _handleUnlinkDevice(name),
                    icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFEF4444), size: 20),
                    tooltip: 'Unlink Device',
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildFacilitatingCard(BuildContext context) {
    final isCloudSyncConnected = UserDatabaseSyncService.instance.isConnected;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.add_link_rounded, color: Color(0xFF0D7FF2), size: 24),
              SizedBox(width: 10),
              Text(
                'Link a New Device (e.g. Android TV)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Enter the 6-digit pairing code shown on your Android TV. It will search automatically.',
            style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 16),

          // Code Input Field with automatic search on 6 digits
          TextField(
            controller: _codeController,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            onChanged: (val) {
              final clean = val.replaceAll(RegExp(r'\D'), '');
              if (clean.length == 6) {
                _handleCheckCode(clean);
              } else {
                if (_foundPairingInfo != null || _pairingErrorMessage != null) {
                  setState(() {
                    _foundPairingInfo = null;
                    _pairingErrorMessage = null;
                  });
                }
              }
            },
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 6,
            ),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              hintText: '• • • • • •',
              hintStyle: TextStyle(color: Colors.grey[600], letterSpacing: 6),
              filled: true,
              fillColor: const Color(0xFF0F172A),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              suffixIcon: _isCheckingCode
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0D7FF2)),
                      ),
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF334155)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF0D7FF2), width: 1.5),
              ),
            ),
          ),

          if (_pairingErrorMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF7F1D1D).withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFEF4444), width: 1),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444), size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _pairingErrorMessage!,
                      style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],

          if (_foundPairingInfo != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF10B981), width: 1.2),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.tv_rounded, color: Color(0xFF10B981), size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Found: ${_foundPairingInfo!.deviceName ?? 'Device'}',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 18),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(color: Color(0xFF334155), height: 1),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Checkbox(
                        value: _shareCloudSync,
                        onChanged: isCloudSyncConnected
                            ? (val) => setState(() => _shareCloudSync = val ?? true)
                            : null,
                        activeColor: const Color(0xFF0D7FF2),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Transfer Cloud Sync Credentials',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              isCloudSyncConnected
                                  ? 'Share your personal Supabase project so watch history stays in sync.'
                                  : 'Connect Cloud Sync on this device first to share credentials.',
                              style: TextStyle(
                                fontSize: 11,
                                color: isCloudSyncConnected ? const Color(0xFF94A3B8) : const Color(0xFFF59E0B),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _isFulfilling ? null : _handleConfirmPairing,
                    icon: _isFulfilling
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send_rounded, size: 18, color: Colors.white),
                    label: const Text(
                      'Confirm & Link Device',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReceivingCard(BuildContext context, {required bool autoStartPrompt}) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _activeSession != null ? const Color(0xFF10B981) : const Color(0xFF334155),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.qr_code_2_rounded, color: Color(0xFF10B981), size: 24),
              const SizedBox(width: 10),
              Text(
                autoStartPrompt ? 'Pair with Phone or PC' : 'Show Pairing Code for this Device',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Display a pairing code to link from your phone or PC without typing credentials.',
            style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 16),

          if (_activeSession == null) ...[
            TvFocusable(
              autoFocus: true,
              scaleFactor: 1.04,
              focusedBorderColor: const Color(0xFF10B981),
              focusedBorderWidth: 3.0,
              focusedBackgroundColor: const Color(0xFF059669),
              normalBackgroundColor: const Color(0xFF10B981),
              borderRadius: BorderRadius.circular(10),
              padding: const EdgeInsets.symmetric(vertical: 16),
              onTap: _isCreatingSession ? () {} : _startReceivingSession,
              child: Center(
                child: _isCreatingSession
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                      )
                    : const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.vpn_key_rounded, size: 20, color: Colors.white),
                          SizedBox(width: 8),
                          Text(
                            'Show Pairing Code',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            if (_receiveErrorMessage != null) ...[
              const SizedBox(height: 10),
              Text(
                _receiveErrorMessage!,
                style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12),
              ),
            ],
          ] else ...[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF10B981), width: 1.5),
              ),
              child: Column(
                children: [
                  const Text(
                    'PAIRING CODE',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_activeSession!.code.substring(0, 3)} - ${_activeSession!.code.substring(3)}',
                    style: const TextStyle(
                      fontSize: 38,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 4,
                      color: Color(0xFF10B981),
                    ),
                  ),
                  const SizedBox(height: 16),

                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(12),
                      child: QrImageView(
                        data: 'wtt://pair?code=${_activeSession!.code}',
                        version: QrVersions.auto,
                        size: 160.0,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),
                  Text(
                    'Expires in ${_secondsRemaining ~/ 60}:${(_secondsRemaining % 60).toString().padLeft(2, '0')}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _secondsRemaining < 60 ? const Color(0xFFEF4444) : const Color(0xFF94A3B8),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF10B981)),
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Waiting for facilitating device...',
                        style: TextStyle(fontSize: 12, color: Color(0xFFCBD5E1)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              focusedBorderColor: Colors.white70,
              focusedBorderWidth: 1.5,
              onTap: () {
                _countdownTimer?.cancel();
                setState(() {
                  _activeSession = null;
                });
              },
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: const Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.close, size: 16, color: Colors.white70),
                    SizedBox(width: 6),
                    Text('Cancel Pairing', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
