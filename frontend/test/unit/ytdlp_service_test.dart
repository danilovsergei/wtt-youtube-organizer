import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/video/ytdlp/ytdlp_service.dart';
import 'package:flutter_app/video/ytdlp/linux_ytdlp.dart';
import 'package:flutter_app/video/ytdlp/test_ytdlp.dart';

void main() {
  group('YtDlpService & Models Unit Tests', () {
    test('YtStreamInfo equality and toString', () {
      final s1 = const YtStreamInfo(1080, 'https://example.com/1080.mp4');
      final s2 = const YtStreamInfo(1080, 'https://example.com/1080.mp4');
      final s3 = const YtStreamInfo(720, 'https://example.com/720.mp4');

      expect(s1, equals(s2));
      expect(s1, isNot(equals(s3)));
      expect(s1.toString(), contains('1080p'));
    });

    test('TestYtDlpService returns local stream and resolution metadata', () async {
      final testService = TestYtDlpService(
        localVideoPath: 'test/assets/test_video.mp4',
        mockResolutions: [1080, 720, 480],
        mockAudioUrl: 'test/assets/audio.m4a',
      );

      final metadata = await testService.getVideoStreamMetadata('sample_id');

      expect(metadata.videoStreams.length, 3);
      expect(metadata.availableResolutions, [1080, 720, 480]);
      expect(metadata.videoStreams.first.height, 1080);
      expect(metadata.videoStreams.first.url, endsWith('test/assets/test_video.mp4'));
      expect(metadata.audioUrl, 'test/assets/audio.m4a');
      expect(metadata.httpHeaders['User-Agent'], 'Test-Agent');

      final resolutions = await testService.getVideoResolutions('sample_id');
      expect(resolutions, [1080, 720, 480]);
    });

    test('TestYtDlpService custom response registration', () async {
      final testService = TestYtDlpService();
      const customMeta = VideoStreamMetadata(
        videoStreams: [YtStreamInfo(360, 'local_360.mp4')],
        audioUrl: 'local_audio.m4a',
      );

      testService.registerMockMetadata('special_id', customMeta);

      final result = await testService.getVideoStreamMetadata('special_id');
      expect(result.videoStreams.first.height, 360);
      expect(result.videoStreams.first.url, 'local_360.mp4');

      // Unregistered ID falls back to default
      final defaultResult = await testService.getVideoStreamMetadata('other_id');
      expect(defaultResult.availableResolutions, [1080, 720, 480, 360]);
    });

    test('LinuxYtDlpService.parseManifest sorts video descending, audio by abr, and deduplicates', () {
      final mockManifest = {
        'formats': [
          // Audio streams
          {'acodec': 'mp4a.40.2', 'vcodec': 'none', 'abr': 128, 'url': 'https://audio.com/128k', 'height': null},
          {'acodec': 'opus', 'vcodec': 'none', 'abr': 160, 'url': 'https://audio.com/160k', 'height': null},
          // Video streams (unsorted, with duplicates)
          {'vcodec': 'avc1.64001f', 'acodec': 'none', 'height': 480, 'url': 'https://video.com/480.mp4'},
          {'vcodec': 'vp9', 'acodec': 'none', 'height': 1080, 'url': 'https://video.com/1080.mp4'},
          {'vcodec': 'av01.0.08M.08', 'acodec': 'none', 'height': 720, 'url': 'https://video.com/720.mp4'},
          {'vcodec': 'avc1.4d401f', 'acodec': 'none', 'height': 1080, 'url': 'https://video.com/1080_dup.mp4'}, // Duplicate 1080p
        ],
        'http_headers': {
          'User-Agent': 'CustomBot/2.0',
        },
      };

      final metadata = LinuxYtDlpService.parseManifest(mockManifest);

      // Verify video sorting (1080, 720, 480)
      expect(metadata.availableResolutions, [1080, 720, 480]);
      // Verify duplicate 1080p was dropped, keeping first
      expect(metadata.videoStreams.first.url, 'https://video.com/1080_dup.mp4');

      // Verify best audio by ABR (160k > 128k)
      expect(metadata.audioUrl, 'https://audio.com/160k');

      // Verify headers extracted
      expect(metadata.httpHeaders['User-Agent'], 'CustomBot/2.0');
      expect(metadata.httpHeaders['Referer'], 'https://www.youtube.com/');
    });

    test('LinuxYtDlpService.parseManifest handles empty formats gracefully', () {
      final metadata = LinuxYtDlpService.parseManifest({'formats': []});
      expect(metadata.videoStreams, isEmpty);
      expect(metadata.audioUrl, isNull);
    });

    test('REGRESSION GUARD: parseManifest strictly prioritizes HLS format 312 over split DASH format 299', () {
      final mockManifest = {
        'formats': [
          // Direct HTTPS DASH video stream (format 299)
          {
            'format_id': '299',
            'vcodec': 'avc1.64002A',
            'acodec': 'none',
            'height': 1080,
            'protocol': 'https',
            'url': 'https://rr4---sn-o097znsd.googlevideo.com/videoplayback?itag=299',
          },
          // Native HLS stream (format 312) - must be prioritized to bypass IP-pinning 403s
          {
            'format_id': '312',
            'vcodec': 'avc1.64002A',
            'acodec': 'none',
            'height': 1080,
            'protocol': 'm3u8_native',
            'url': 'https://manifest.googlevideo.com/api/manifest/hls_playlist/format_312.m3u8',
          },
          // Audio stream
          {
            'format_id': '140',
            'acodec': 'mp4a.40.2',
            'vcodec': 'none',
            'abr': 128,
            'url': 'https://audio.com/140.m4a',
          },
        ],
      };

      final metadata = LinuxYtDlpService.parseManifest(mockManifest);

      // Must select HLS format 312 as primary 1080p stream
      expect(metadata.videoStreams.first.url, contains('hls_playlist/format_312.m3u8'));
      expect(metadata.videoStreams.first.height, 1080);
    });

    test('REGRESSION GUARD: buildArgs includes Deno JS runtime and NEVER includes forced IPv4 (-4)', () {
      // 1. With Deno present
      final argsWithDeno = LinuxYtDlpService.buildArgs('sample_yt_id', denoPath: '/app/bin/deno');
      expect(argsWithDeno, containsAll(['--js-runtimes', 'deno:/app/bin/deno']));
      expect(argsWithDeno, isNot(contains('-4')));
      expect(argsWithDeno, isNot(contains('--force-ipv4')));

      // 2. Without Deno present
      final argsWithoutDeno = LinuxYtDlpService.buildArgs('sample_yt_id');
      expect(argsWithoutDeno, isNot(contains('--js-runtimes')));
      expect(argsWithoutDeno, isNot(contains('-4')));
      expect(argsWithoutDeno, isNot(contains('--force-ipv4')));
    });

    test('YtDlpService singleton instance is swappable', () {
      final original = YtDlpService.instance;
      final testService = TestYtDlpService();

      YtDlpService.instance = testService;
      expect(YtDlpService.instance, isA<TestYtDlpService>());

      // Restore
      YtDlpService.instance = original;
      expect(YtDlpService.instance, isA<LinuxYtDlpService>());
    });
  });
}
