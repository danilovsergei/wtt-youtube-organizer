import 'dart:io';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/log_service.dart';
import 'tv_focusable.dart';

class DiagnosticsScreen extends StatefulWidget {
  final VoidCallback? onClose;

  const DiagnosticsScreen({super.key, this.onClose});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final ScrollController _scrollController = ScrollController();
  final bool _autoScroll = true;
  bool _isUploading = false;
  String? _filterQuery;
  String _activeFilter = 'All';

  @override
  void initState() {
    super.initState();
    LogService.instance.addListener(_onLogsUpdated);
  }

  @override
  void dispose() {
    LogService.instance.removeListener(_onLogsUpdated);
    _scrollController.dispose();
    super.dispose();
  }

  void _onLogsUpdated() {
    if (mounted) {
      setState(() {});
      if (_autoScroll && _scrollController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          }
        });
      }
    }
  }

  Future<void> _handleUpload() async {
    setState(() => _isUploading = true);
    try {
      final url = await LogService.instance.uploadLogs();
      if (!mounted) return;
      setState(() => _isUploading = false);
      _showShareDialog(url);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isUploading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Upload failed: $e'),
          backgroundColor: Colors.red[800],
        ),
      );
    }
  }

  void _showShareDialog(String url) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF141F2B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF223649), width: 1.5),
        ),
        title: Row(
          children: const [
            Icon(Icons.share, color: Color(0xFF0D7FF2)),
            SizedBox(width: 10),
            Text(
              'Logs Uploaded Successfully',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Share this link or scan the QR code to view logs (valid for 7 days):',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 16),
              // QR Code for easy TV-to-Phone scanning
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: url,
                  version: QrVersions.auto,
                  size: 180.0,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D1319),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF223649)),
                ),
                child: SelectableText(
                  url,
                  style: const TextStyle(
                    color: Color(0xFF0D7FF2),
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy Link'),
            onPressed: () async {
              await LogService.instance.copyToClipboard(url);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Link copied to clipboard!'),
                    duration: Duration(seconds: 2),
                  ),
                );
                Navigator.of(context).pop();
              }
            },
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0D7FF2),
            ),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Color _getLogColor(String msg) {
    if (msg.contains('EXCEPTION') || msg.contains('error') || msg.contains('Failed')) {
      return const Color(0xFFFF5252);
    }
    if (msg.contains('[AV_SYNC]')) {
      return const Color(0xFF00E5FF);
    }
    if (msg.contains('[MPV]')) {
      return const Color(0xFF69F0AE);
    }
    if (msg.contains('[WTT_PLAYER]')) {
      return const Color(0xFFFFD740);
    }
    return Colors.white70;
  }

  @override
  Widget build(BuildContext context) {
    final allLogs = LogService.instance.logs;
    final filteredLogs = allLogs.where((entry) {
      if (_activeFilter == 'MPV' && !entry.message.contains('[MPV]')) return false;
      if (_activeFilter == 'A/V Sync' && !entry.message.contains('[AV_SYNC]')) return false;
      if (_activeFilter == 'Errors' &&
          !(entry.message.contains('error') ||
              entry.message.contains('EXCEPTION') ||
              entry.message.contains('Failed'))) {
        return false;
      }
      if (_filterQuery != null && _filterQuery!.isNotEmpty) {
        return entry.message.toLowerCase().contains(_filterQuery!.toLowerCase());
      }
      return true;
    }).toList();

    return Container(
      color: const Color(0xFF090D12),
      child: SafeArea(
        child: Column(
          children: [
            // Header Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                color: Color(0xFF141F2B),
                border: Border(bottom: BorderSide(color: Color(0xFF223649))),
              ),
              child: Row(
                children: [
                  const Icon(Icons.terminal, color: Color(0xFF0D7FF2)),
                  const SizedBox(width: 8),
                  const Text(
                    'Diagnostics & Logs',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  // Device Badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF223649),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      Platform.operatingSystem.toUpperCase(),
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: 'Close',
                    onPressed: () {
                      if (widget.onClose != null) {
                        widget.onClose!();
                      } else if (Navigator.of(context).canPop()) {
                        Navigator.of(context).pop();
                      }
                    },
                  ),
                ],
              ),
            ),

            // Toolbar / Filter Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: const Color(0xFF0D1319),
              child: Row(
                children: [
                  _buildFilterChip('All'),
                  const SizedBox(width: 6),
                  _buildFilterChip('A/V Sync'),
                  const SizedBox(width: 6),
                  _buildFilterChip('MPV'),
                  const SizedBox(width: 6),
                  _buildFilterChip('Errors'),
                  const Spacer(),
                  // Upload & Share Button
                  TvFocusable(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      if (!_isUploading) {
                        _handleUpload();
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D7FF2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: _isUploading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(Icons.cloud_upload, color: Colors.white, size: 16),
                                SizedBox(width: 6),
                                Text(
                                  'Share Link',
                                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Clear Button
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 20),
                    tooltip: 'Clear Logs',
                    onPressed: () => LogService.instance.clear(),
                  ),
                ],
              ),
            ),

            // Console Logs Output
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF223649)),
                ),
                child: filteredLogs.isEmpty
                    ? const Center(
                        child: Text(
                          'No logs recorded yet. Play a match to capture logs.',
                          style: TextStyle(color: Colors.grey, fontSize: 14),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        itemCount: filteredLogs.length,
                        itemBuilder: (context, index) {
                          final entry = filteredLogs[index];
                          return SelectableText.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '[${entry.formattedTime}] ',
                                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                                ),
                                TextSpan(
                                  text: entry.message,
                                  style: TextStyle(
                                    color: _getLogColor(entry.message),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            style: const TextStyle(fontFamily: 'monospace'),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label) {
    final isSelected = _activeFilter == label;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
      onTap: () => setState(() => _activeFilter = label),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0D7FF2) : const Color(0xFF1E2D3D),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.grey[400],
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    ),
    );
  }
}
