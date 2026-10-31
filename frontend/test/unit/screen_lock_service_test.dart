import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/video/screen_inhibitor.dart';

class MockScreenLockInhibitor implements ScreenLockInhibitor {
  int enableCalls = 0;
  int disableCalls = 0;

  @override
  Future<void> enable() async {
    enableCalls++;
  }

  @override
  Future<void> disable() async {
    disableCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScreenLockService & Periodic Inhibitor Unit Tests', () {
    late ScreenLockInhibitor originalInstance;

    setUp(() {
      originalInstance = ScreenLockService.instance;
    });

    tearDown(() {
      ScreenLockService.instance = originalInstance;
    });

    test('ScreenLockService defaults to DefaultScreenLockInhibitor', () {
      expect(ScreenLockService.instance, isA<DefaultScreenLockInhibitor>());
    });

    test('REGRESSION GUARD: ScreenLockService invokes inhibitor when match is playing and paused', () async {
      final mock = MockScreenLockInhibitor();
      ScreenLockService.instance = mock;

      expect(mock.enableCalls, 0);
      expect(mock.disableCalls, 0);

      // Match starts playing: must avoid screen locking
      await ScreenLockService.enable();
      expect(mock.enableCalls, 1);
      expect(mock.disableCalls, 0);

      // Subsequent play state: avoids screen locking
      await ScreenLockService.enable();
      expect(mock.enableCalls, 2);

      // Match paused or stopped: restores screen lock
      await ScreenLockService.disable();
      expect(mock.enableCalls, 2);
      expect(mock.disableCalls, 1);
    });

    test('REGRESSION GUARD: DefaultScreenLockInhibitor runs periodic heartbeat while active and cancels on disable', () async {
      // Create inhibitor with fast heartbeat for unit testing (30ms instead of 30s)
      final inhibitor = DefaultScreenLockInhibitor(
        heartbeatInterval: const Duration(milliseconds: 30),
      );

      expect(inhibitor.isHeartbeatActive, isFalse);
      expect(inhibitor.heartbeatCount, 0);

      // Enable: starts periodic heartbeat
      await inhibitor.enable();
      expect(inhibitor.isHeartbeatActive, isTrue);

      // Wait for at least 3 periodic heartbeats to fire
      await Future.delayed(const Duration(milliseconds: 110));
      expect(inhibitor.heartbeatCount, greaterThanOrEqualTo(2));
      final countBeforeDisable = inhibitor.heartbeatCount;

      // Disable: immediately cancels periodic heartbeat
      await inhibitor.disable();
      expect(inhibitor.isHeartbeatActive, isFalse);

      // Wait additional time: heartbeat count must not increase after disable
      await Future.delayed(const Duration(milliseconds: 60));
      expect(inhibitor.heartbeatCount, countBeforeDisable);
    });

    test('LinuxScreenInhibitor simulateUserActivity executes safely', () async {
      // Must execute gracefully without crashing on headless or test environments
      await LinuxScreenInhibitor.simulateUserActivity();
    });
  });
}
