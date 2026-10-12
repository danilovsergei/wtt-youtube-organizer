import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class LogEntry {
  final DateTime timestamp;
  final String message;

  const LogEntry({
    required this.timestamp,
    required this.message,
  });

  String get formattedTime {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  @override
  String toString() => '[$formattedTime] $message';
}

class LogService extends ChangeNotifier {
  static final LogService instance = LogService._();
  LogService._();

  static const int maxEntries = 1000;
  final DoubleLinkedQueue<LogEntry> _logs = DoubleLinkedQueue<LogEntry>();

  List<LogEntry> get logs => _logs.toList();

  void log(String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      message: message,
    );
    _logs.addLast(entry);
    while (_logs.length > maxEntries) {
      _logs.removeFirst();
    }
    notifyListeners();
  }

  void clear() {
    _logs.clear();
    notifyListeners();
  }

  String exportFormattedLogs() {
    final buffer = StringBuffer();
    buffer.writeln('==================================================');
    buffer.writeln('📋 WTT Organizer Diagnostics Report');
    buffer.writeln('📅 Generated: ${DateTime.now().toUtc().toIso8601String()}');
    buffer.writeln('💻 OS: ${Platform.operatingSystem} (${Platform.operatingSystemVersion})');
    buffer.writeln('🔢 Total Log Entries: ${_logs.length}');
    buffer.writeln('==================================================');
    buffer.writeln();

    for (final entry in _logs) {
      buffer.writeln(entry.toString());
    }
    return buffer.toString();
  }

  Future<String> uploadLogs({String? title}) async {
    final content = exportFormattedLogs();
    try {
      final response = await http.post(
        Uri.parse('https://dpaste.org/api/'),
        body: {
          'content': content,
          'title': title ?? 'WTT Organizer Logs (${Platform.operatingSystem})',
          'expiry_days': '7',
          'syntax': 'text',
        },
      ).timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        return response.body.trim();
      } else {
        throw Exception('Failed to upload logs (HTTP ${response.statusCode}): ${response.body}');
      }
    } catch (e) {
      throw Exception('Error uploading logs: $e');
    }
  }

  Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }
}
