import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/playback_progress_service.dart';

void main() {
  group('PlaybackProgressService', () {
    late Directory tempDir;
    late File tempFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('progress_test_');
      tempFile = File('${tempDir.path}/test_progress.json');
      PlaybackProgressService.instance.resetForTesting();
      PlaybackProgressService.instance.customStoragePath = tempFile.path;
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('returns defaultOffsetSeconds when no progress is saved', () async {
      final pos = await PlaybackProgressService.instance.getResumePosition(
        matchId: 'm_test_1',
        defaultOffsetSeconds: 120,
      );
      expect(pos, 120);
    });

    test('saves progress and returns saved position', () async {
      await PlaybackProgressService.instance.saveProgress(
        matchId: 'm_test_1',
        positionSeconds: 245,
        defaultOffsetSeconds: 120,
      );

      final pos = await PlaybackProgressService.instance.getResumePosition(
        matchId: 'm_test_1',
        defaultOffsetSeconds: 120,
      );
      expect(pos, 245);
    });

    test('ignores progress smaller than default offset', () async {
      await PlaybackProgressService.instance.saveProgress(
        matchId: 'm_test_1',
        positionSeconds: 50,
        defaultOffsetSeconds: 120,
      );

      final pos = await PlaybackProgressService.instance.getResumePosition(
        matchId: 'm_test_1',
        defaultOffsetSeconds: 120,
      );
      expect(pos, 120);
    });

    test('resets to defaultOffsetSeconds when watched >= 95% of duration', () async {
      // match: start=100s, duration=1000s -> 95% is 100 + 950 = 1050s
      await PlaybackProgressService.instance.saveProgress(
        matchId: 'm_test_finished',
        positionSeconds: 1060,
        defaultOffsetSeconds: 100,
        matchDurationSeconds: 1000,
      );

      final pos = await PlaybackProgressService.instance.getResumePosition(
        matchId: 'm_test_finished',
        defaultOffsetSeconds: 100,
        matchDurationSeconds: 1000,
      );
      expect(pos, 100, reason: 'Completed match (>95%) should restart from beginning');
    });

    test('persists atomically to disk and reloads in a fresh instance', () async {
      await PlaybackProgressService.instance.saveProgress(
        matchId: 'm_saved_disk',
        positionSeconds: 380,
        defaultOffsetSeconds: 100,
      );

      expect(tempFile.existsSync(), isTrue);

      // Reset in-memory cache and reload from disk
      PlaybackProgressService.instance.resetForTesting();
      PlaybackProgressService.instance.customStoragePath = tempFile.path;

      final pos = await PlaybackProgressService.instance.getResumePosition(
        matchId: 'm_saved_disk',
        defaultOffsetSeconds: 100,
      );
      expect(pos, 380);
    });

    test('handles corrupt JSON file gracefully', () async {
      tempFile.writeAsStringSync('{ invalid json ...');

      final pos = await PlaybackProgressService.instance.getResumePosition(
        matchId: 'm_corrupt',
        defaultOffsetSeconds: 60,
      );
      expect(pos, 60);
    });

    test('clears progress for match', () async {
      await PlaybackProgressService.instance.saveProgress(
        matchId: 'm_clear',
        positionSeconds: 500,
        defaultOffsetSeconds: 100,
      );

      await PlaybackProgressService.instance.clearProgress('m_clear');

      final pos = await PlaybackProgressService.instance.getResumePosition(
        matchId: 'm_clear',
        defaultOffsetSeconds: 100,
      );
      expect(pos, 100);
    });

    test('getProgressRatio returns correct ratio for matches in progress', () async {
      // No progress -> null
      expect(
        PlaybackProgressService.instance.getProgressRatio(
          matchId: 'm_ratio',
          defaultOffsetSeconds: 100,
          matchDurationSeconds: 1000,
        ),
        isNull,
      );

      // 50% watched (100 offset + 500 watched = 600s) -> 0.5
      await PlaybackProgressService.instance.saveProgress(
        matchId: 'm_ratio',
        positionSeconds: 600,
        defaultOffsetSeconds: 100,
        matchDurationSeconds: 1000,
      );
      expect(
        PlaybackProgressService.instance.getProgressRatio(
          matchId: 'm_ratio',
          defaultOffsetSeconds: 100,
          matchDurationSeconds: 1000,
        ),
        closeTo(0.5, 0.01),
      );

      // Finished (96% watched) -> null
      await PlaybackProgressService.instance.saveProgress(
        matchId: 'm_ratio',
        positionSeconds: 1060,
        defaultOffsetSeconds: 100,
        matchDurationSeconds: 1000,
      );
      expect(
        PlaybackProgressService.instance.getProgressRatio(
          matchId: 'm_ratio',
          defaultOffsetSeconds: 100,
          matchDurationSeconds: 1000,
        ),
        isNull,
      );
    });

    test('notifies listeners when progress changes', () async {
      int notifyCount = 0;
      PlaybackProgressService.instance.addListener(() {
        notifyCount++;
      });

      await PlaybackProgressService.instance.saveProgress(
        matchId: 'm_notify',
        positionSeconds: 200,
        defaultOffsetSeconds: 100,
      );
      expect(notifyCount, greaterThanOrEqualTo(1));

      await PlaybackProgressService.instance.clearProgress('m_notify');
      expect(notifyCount, greaterThanOrEqualTo(2));
    });
  });
}
