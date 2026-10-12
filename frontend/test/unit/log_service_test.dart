import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/log_service.dart';

void main() {
  group('LogService Unit Tests', () {
    setUp(() {
      LogService.instance.clear();
    });

    test('log() records entries and formats timestamp', () {
      LogService.instance.log('Test message 1');
      LogService.instance.log('Test message 2');

      final logs = LogService.instance.logs;
      expect(logs.length, equals(2));
      expect(logs[0].message, equals('Test message 1'));
      expect(logs[1].message, equals('Test message 2'));
      expect(logs[0].formattedTime, matches(RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3}')));
    });

    test('clear() flushes all entries', () {
      LogService.instance.log('Entry to clear');
      expect(LogService.instance.logs.length, equals(1));

      LogService.instance.clear();
      expect(LogService.instance.logs, isEmpty);
    });

    test('exportFormattedLogs() includes system metadata header', () {
      LogService.instance.log('Sample log entry');
      final export = LogService.instance.exportFormattedLogs();

      expect(export, contains('WTT Organizer Diagnostics Report'));
      expect(export, contains('OS:'));
      expect(export, contains('Sample log entry'));
    });

    test('Log buffer caps at maxEntries (ring buffer behavior)', () {
      for (int i = 0; i < LogService.maxEntries + 50; i++) {
        LogService.instance.log('Message $i');
      }

      final logs = LogService.instance.logs;
      expect(logs.length, equals(LogService.maxEntries));
      // First 50 should have been dropped
      expect(logs.first.message, equals('Message 50'));
      expect(logs.last.message, equals('Message ${LogService.maxEntries + 49}'));
    });
  });
}
