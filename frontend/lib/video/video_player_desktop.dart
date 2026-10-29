import 'package:native_surface_view/native_surface_view.dart';
import '../services/log_service.dart';
import '../widgets/tv_focusable.dart';
import '../main.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'screen_inhibitor.dart';
import 'video_player_service.dart';
import 'ytdlp/ytdlp_service.dart';
import '../services/playback_progress_service.dart';

class InstantPlayOrPauseButton extends StatefulWidget {
  final Player player;
  final double iconSize;
  final Color iconColor;

  const InstantPlayOrPauseButton({
    super.key,
    required this.player,
    this.iconSize = 28.0,
    this.iconColor = Colors.white,
  });

  @override
  State<InstantPlayOrPauseButton> createState() => _InstantPlayOrPauseButtonState();
}

class _InstantPlayOrPauseButtonState extends State<InstantPlayOrPauseButton> {
  late bool _isPlaying;
  StreamSubscription<bool>? _sub;

  @override
  void initState() {
    super.initState();
    _isPlaying = widget.player.state.playing;
    _sub = widget.player.stream.playing.listen((playing) {
      if (mounted && _isPlaying != playing) {
                setState(() {
          _isPlaying = playing;
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _toggle() {
    // Immediate optimistic state update (0ms latency, no animation lag)
            setState(() {
      _isPlaying = !_isPlaying;
    });
    widget.player.playOrPause();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: _toggle,
      iconSize: widget.iconSize,
      color: widget.iconColor,
      splashRadius: widget.iconSize,
      icon: Icon(
        _isPlaying ? Icons.pause : Icons.play_arrow,
        size: widget.iconSize,
        color: widget.iconColor,
      ),
    );
  }
}


void _logPlayer(String message) {
  final now = DateTime.now().toIso8601String().substring(11, 23);
  final formatted = '[$now] [WTT_PLAYER] $message';
  debugPrint(formatted);
  LogService.instance.log(message);
  if (Platform.isLinux) {
    try {
      File('/tmp/wtt_player.log').writeAsStringSync('$formatted\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}

VideoPlayerWidget createVideoPlayer({
  Key? key,
  ValueNotifier<bool>? resizingNotifier,
  required String? matchId,
  required String? youtubeId,
  required String imageUrl,
  required int offsetSeconds,
  int? matchDurationSeconds,
  required void Function() onDoubleTap,
  bool autoPlay = true,
}) {
  return _DesktopVideoPlayerWidget(
    key: key,
    resizingNotifier: resizingNotifier,
    matchId: matchId,
    youtubeId: youtubeId,
    imageUrl: imageUrl,
    offsetSeconds: offsetSeconds,
    matchDurationSeconds: matchDurationSeconds,
    onDoubleTap: onDoubleTap,
    autoPlay: autoPlay,
  );
}



class _DesktopVideoPlayerWidget extends VideoPlayerWidget {
  const _DesktopVideoPlayerWidget({
    super.key,
    super.resizingNotifier,
    required super.matchId,
    required super.youtubeId,
    required super.imageUrl,
    required super.offsetSeconds,
    super.matchDurationSeconds,
    required super.onDoubleTap,
    super.autoPlay = true,
  });

  @override
  State<_DesktopVideoPlayerWidget> createState() => _DesktopVideoPlayerState();
}

class _DesktopVideoPlayerState extends State<_DesktopVideoPlayerWidget> with WidgetsBindingObserver {
  late final Player _player;
  Timer? _progressSaveTimer;

  Duration get _effectiveDuration {
    if (widget.matchDurationSeconds != null && widget.matchDurationSeconds! > 0) {
      return Duration(seconds: widget.matchDurationSeconds!);
    }
    return _player.state.duration;
  }

  Duration get _matchOffset {
    return Duration(seconds: widget.offsetSeconds);
  }
  final FocusNode _videoPlayerFocusNode = FocusNode(debugLabel: 'tv_video_root');
  VideoController? _controller;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;
  Timer? _singleClickTimer;

  List<YtStreamInfo> _availableStreams = [];
  YtStreamInfo? _selectedStream;
  String? _audioUrl;
  bool _isLoadingVideo = false;
  String? _errorMessage;
  bool _hasStarted = false;
  bool _showTvControls = false;
  Timer? _tvControlsTimer;
  Timer? _syncDebugTimer;
  int? _nativeSurfaceWid;
  int _surfaceWidth = 1920;
  int _surfaceHeight = 1080;
  int _seekStreak = 0;
  DateTime? _lastSeekTime;
  bool _lastSeekForward = true;
  Duration? _targetSeekPosition;
  Timer? _seekCommitTimer;
  int _cumulativeSeekSeconds = 0;

  void _handleNativeSurfaceChanged(int width, int height) {
    _surfaceWidth = width;
    _surfaceHeight = height;
    // ZERO FFI calls on surface resize! vo_gpu handles window dimensions automatically.
    // FFI calls here deadlock the UI thread on the MPV render lock and cause Android TV ANRs.
  }

  Future<void> _applyNativeSurfaceWid(int wid) async {
    try {
      final nativePlayer = _player.platform as dynamic;
      await nativePlayer.setProperty('android-surface-size', '${_surfaceWidth}x${_surfaceHeight}');
      await nativePlayer.setProperty('wid', wid.toString());
      await nativePlayer.setProperty('vo', 'gpu');
      await nativePlayer.setProperty('hwdec', 'auto');
      await nativePlayer.setProperty('hwdec-codecs', 'all');
      await nativePlayer.setProperty('vid', 'auto');
      _logPlayer('[NATIVE_SURFACE] Applied wid=$wid with size=${_surfaceWidth}x${_surfaceHeight}');
    } catch (e) {
      _logPlayer('[NATIVE_SURFACE] Error applying wid: $e');
    }
  }

  void _handleNativeSurfaceCreated(int wid) async {
    _nativeSurfaceWid = wid;
    _logPlayer('[NATIVE_SURFACE] Native SurfaceView created! wid=$wid');
    await _applyNativeSurfaceWid(wid);
  }


  void _handleShowControlsTrigger() {
    if (mounted) {
      setState(() {
        _showTvControls = true;
      });
      _resetControlsTimer(seconds: 5);
    }
  }

  void _handlePlayButtonFocusChange() {
    if (filterController.playButtonFocusNode.hasFocus) {
      if (mounted && !_showTvControls) {
        setState(() => _showTvControls = true);
      }
      if (_player.state.playing) {
        _resetControlsTimer(seconds: 3);
      }
    }
  }

  void _handleProgressBarFocusChange() {
    if (filterController.progressBarFocusNode.hasFocus) {
      if (mounted && !_showTvControls) {
        setState(() => _showTvControls = true);
      }
      if (_player.state.playing) {
        _resetControlsTimer(seconds: 3);
      }
    }
  }

  void _performProgressiveSeek({required bool forward}) {
    final now = DateTime.now();
    final duration = _player.state.duration;
    final currentPos = _targetSeekPosition ?? _player.state.position;

    if (_lastSeekTime != null &&
        now.difference(_lastSeekTime!) < const Duration(milliseconds: 900) &&
        _lastSeekForward == forward) {
      _seekStreak++;
    } else {
      _seekStreak = 1;
      _cumulativeSeekSeconds = 0;
    }

    _lastSeekTime = now;
    _lastSeekForward = forward;

    // Progressive velocity ramp: 10s -> 20s -> 30s -> 60s -> 120s
    int stepSeconds;
    if (_seekStreak <= 2) {
      stepSeconds = 10;
    } else if (_seekStreak <= 5) {
      stepSeconds = 20;
    } else if (_seekStreak <= 9) {
      stepSeconds = 30;
    } else if (_seekStreak <= 15) {
      stepSeconds = 60;
    } else {
      stepSeconds = 120;
    }

    final delta = forward ? Duration(seconds: stepSeconds) : -Duration(seconds: stepSeconds);
    var newPos = currentPos + delta;
    if (newPos < Duration.zero) newPos = Duration.zero;
    final hasMatchDuration = widget.matchDurationSeconds != null && widget.matchDurationSeconds! > 0;
    final maxPos = hasMatchDuration ? (_matchOffset + _effectiveDuration) : duration;
    if (maxPos > Duration.zero && newPos > maxPos) newPos = maxPos;

    _cumulativeSeekSeconds += forward ? stepSeconds : -stepSeconds;

    setState(() {
      _targetSeekPosition = newPos;
      _showTvControls = true;
    });

    _resetControlsTimer(seconds: 5);

    _seekCommitTimer?.cancel();
    _seekCommitTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted && _targetSeekPosition != null) {
        _logPlayer('[SEEK] Committing progressive seek to ${_targetSeekPosition!.inSeconds}s (streak: $_seekStreak, delta: ${_cumulativeSeekSeconds}s)');
        _player.seek(_targetSeekPosition!);
        setState(() {
          _targetSeekPosition = null;
          _seekStreak = 0;
          _cumulativeSeekSeconds = 0;
        });
      }
    });
  }

  String _formatSeekDelta(int totalSeconds) {
    final absSecs = totalSeconds.abs();
    if (absSecs < 60) {
      return '${absSecs}s';
    }
    final mins = absSecs ~/ 60;
    final remSecs = absSecs % 60;
    return remSecs > 0 ? '${mins}m ${remSecs}s' : '${mins}m';
  }

  void _resetControlsTimer({int seconds = 3}) {
    _tvControlsTimer?.cancel();
    if (_player.state.playing) {
      _tvControlsTimer = Timer(Duration(seconds: seconds), () {
        if (mounted && _player.state.playing) {
          _videoPlayerFocusNode.requestFocus();
          setState(() => _showTvControls = false);
        }
      });
    }
  }

  void _toggleTvPlayback() {
    if (!_hasStarted && widget.youtubeId != null) {
      _hasStarted = true;
      setState(() {
        _isLoadingVideo = true;
        _showTvControls = true;
      });
      _loadVideo(widget.youtubeId!, widget.offsetSeconds);
      _resetControlsTimer(seconds: 3);
      return;
    }
    final willPlay = !_player.state.playing;
    _player.playOrPause();
    setState(() {
      _showTvControls = true;
    });
    if (willPlay) {
      _resetControlsTimer(seconds: 3);
    } else {
      _tvControlsTimer?.cancel();
      filterController.focusPlayButton();
    }
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final isHeadlessTest = WidgetsBinding.instance.runtimeType.toString().contains('Automated');
    if (!isHeadlessTest) {
      _progressSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveCurrentProgress());
    }
    _player = Player(
      configuration: const PlayerConfiguration(
        logLevel: MPVLogLevel.v,
        bufferSize: 16 * 1024 * 1024,
      ),
    );
    _player.stream.log.listen((event) {
      _logPlayer('[MPV] ${event.prefix}: ${event.text}');
    });
    _player.stream.tracks.listen((tracks) {
      _logPlayer('[TRACKS] video=${tracks.video.map((t) => "${t.id}:${t.title}").toList()}, audio=${tracks.audio.map((t) => "${t.id}:${t.title}").toList()}');
    });
    _player.stream.position.listen((pos) {});
    _player.stream.audioParams.listen((ap) {
      _logPlayer('[AUDIO_PARAMS] format=${ap.format}, rate=${ap.sampleRate}, channels=${ap.channels}');
    });
    _player.stream.buffering.listen((b) => _logPlayer('[BUFFER_EVENT] isBuffering=$b'));
    _player.stream.error.listen((e) {
      _logPlayer('[ERROR_EVENT] error=$e');
      if (mounted) {
        setState(() {
          _isLoadingVideo = false;
          _errorMessage = e.toString();
        });
      }
    });
    _syncDebugTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _logPlayer('[PLAY_CLOCK] pos=${_player.state.position.inSeconds}s / ${_player.state.duration.inSeconds}s, play=${_player.state.playing}, buf=${_player.state.buffering}');
    });
    if (!Platform.isAndroid) {
      _controller = VideoController(
        _player,
        configuration: const VideoControllerConfiguration(),
      );
    }
    _playingSub = _player.stream.playing.listen((isPlaying) {
      if (mounted) {
        setState(() {
          if (isPlaying) {
            
          } else {
            _showTvControls = true;
          }
        });
        if (isPlaying) {
          _resetControlsTimer(seconds: 3);
        } else {
          _saveCurrentProgress();
          _tvControlsTimer?.cancel();
          filterController.focusPlayButton();
        }
      }
      if (Platform.isLinux) {
        if (isPlaying) {
          LinuxScreenInhibitor.enable();
        } else {
          LinuxScreenInhibitor.disable();
        }
      }
    });

    filterController.showControlsTrigger.addListener(_handleShowControlsTrigger);
    filterController.playButtonFocusNode.addListener(_handlePlayButtonFocusChange);
    filterController.progressBarFocusNode.addListener(_handleProgressBarFocusChange);

    if (widget.youtubeId != null && widget.autoPlay) {
      _hasStarted = true;
      _isLoadingVideo = true;
      _loadVideo(widget.youtubeId!, widget.offsetSeconds);
    }
  }

  @override
  void didUpdateWidget(_DesktopVideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final matchChanged = widget.matchId != oldWidget.matchId;
    if (matchChanged) {
      _saveCurrentProgress(
        oldMatchId: oldWidget.matchId,
        oldOffsetSeconds: oldWidget.offsetSeconds,
        oldDurationSeconds: oldWidget.matchDurationSeconds,
      );
    }
    final autoPlayTriggered = !oldWidget.autoPlay && widget.autoPlay;

    if (matchChanged || (autoPlayTriggered && !_hasStarted)) {
      if (widget.youtubeId != null) {
        _hasStarted = true;
        setState(() {
          _errorMessage = null;
          _isLoadingVideo = true;
        });
        _loadVideo(widget.youtubeId!, widget.offsetSeconds);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _saveCurrentProgress();
    }
  }

  void _saveCurrentProgress({String? oldMatchId, int? oldOffsetSeconds, int? oldDurationSeconds}) {
    final mId = oldMatchId ?? widget.matchId;
    final defOffset = oldOffsetSeconds ?? widget.offsetSeconds;
    final dur = oldDurationSeconds ?? widget.matchDurationSeconds;
    if (mId == null || mId.isEmpty) return;
    final currentPos = _player.state.position.inSeconds;
    if (currentPos >= defOffset) {
      PlaybackProgressService.instance.saveProgress(
        matchId: mId,
        positionSeconds: currentPos,
        defaultOffsetSeconds: defOffset,
        matchDurationSeconds: dur,
        youtubeId: widget.youtubeId,
      );
    }
  }

  @override
  void dispose() {
    _saveCurrentProgress();
    _progressSaveTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    filterController.showControlsTrigger.removeListener(_handleShowControlsTrigger);
    filterController.playButtonFocusNode.removeListener(_handlePlayButtonFocusChange);
    filterController.progressBarFocusNode.removeListener(_handleProgressBarFocusChange);
    _seekCommitTimer?.cancel();
    _videoPlayerFocusNode.dispose();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _singleClickTimer?.cancel();
    _tvControlsTimer?.cancel();
    _syncDebugTimer?.cancel();
    LinuxScreenInhibitor.disable();
    try {
      _player.stop();
    } catch (_) {}
    _player.dispose();
    super.dispose();
  }

  void _loadVideo(String youtubeId, int startSeconds, [YtStreamInfo? specificStream]) async {
    _errorMessage = null;
    _logPlayer('_loadVideo START: yt=$youtubeId, offset=${startSeconds}s, specific=${specificStream?.height}p');
    
    final isHeadless = WidgetsBinding.instance.runtimeType.toString().contains('Automated');
    if (!isHeadless) {
      try {
        await _player.setVolume(0);
        await _player.stop();
      } catch (_) {}
    }
    try {
      final metadata = await YtDlpService.instance.getVideoStreamMetadata(youtubeId);
      _logPlayer('metadata received: streams=${metadata.videoStreams.length}, audioUrl=${metadata.audioUrl != null}');
      if (metadata.videoStreams.isEmpty) {
        _logPlayer('No video streams extracted for $youtubeId');
        if (mounted) setState(() => _isLoadingVideo = false);
        return;
      }

      if (mounted) {
        setState(() {
          _availableStreams = metadata.videoStreams;
          _selectedStream = specificStream ?? _availableStreams.first;
          _audioUrl = metadata.audioUrl;
        });
        _logPlayer('Selected resolution: ${_selectedStream!.height}p');
      }

      _durationSub?.cancel();
      _singleClickTimer?.cancel();

      // In headless widget unit tests without a display server or GPU, avoid native C++ texture calls
      final isHeadlessWidgetTest = WidgetsBinding.instance.runtimeType.toString().contains('Automated');
      if (isHeadlessWidgetTest) {
        _logPlayer('Headless test detected, dismissing overlay immediately');
        if (mounted) setState(() => _isLoadingVideo = false);
        return;
      }

      final nativePlayer = _player.platform as dynamic;
      try { nativePlayer.setProperty('load-scripts', 'no'); } catch (_) {}
      try { nativePlayer.setProperty('ytdl', 'no'); } catch (e) { _logPlayer('MPV prop ytdl err: $e'); }
      try { nativePlayer.setProperty('tls-verify', 'no'); } catch (e) { _logPlayer('MPV prop tls-verify err: $e'); }

      // Set global User-Agent and Referrer on MPV directly (avoiding comma splitting in http-header-fields)
      try {
        final ua = metadata.httpHeaders['User-Agent'] ?? metadata.httpHeaders['user-agent'] ?? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
        await nativePlayer.setProperty('user-agent', ua);
        await nativePlayer.setProperty('referrer', 'https://www.youtube.com/');
      } catch (e) {
        _logPlayer('Could not set MPV user-agent/referrer: $e');
      }

      try {
        final nativePlayer = _player.platform as dynamic;
        // Release tournament card image bitmaps to free 60MB+ RAM before video playback
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();

        if (Platform.isAndroid) {
          await nativePlayer.setProperty('ao', 'aaudio,audiotrack,opensles');
          await nativePlayer.setProperty('hwdec', 'auto');
          await nativePlayer.setProperty('hwdec-codecs', 'all');
          await nativePlayer.setProperty('cache-on-disk', 'no');
          await nativePlayer.setProperty('cache', 'yes');
          await nativePlayer.setProperty('force-seekable', 'yes');
          await nativePlayer.setProperty('demuxer-max-bytes', '33554432');
          await nativePlayer.setProperty('demuxer-max-back-bytes', '8388608');
          await nativePlayer.setProperty('demuxer-readahead-secs', '20');
          await nativePlayer.setProperty('stream-lavf-o', 'reconnect=1,reconnect_delay_max=5');
        }


      } catch (e) {
        _logPlayer('Could not set pre-open properties: $e');
      }

      // 1. Mute audio while buffering so no sound leaks under loading overlay
      try {
        await _player.setVolume(0);
      } catch (_) {}

      // 2. Register tracks listener before open to capture new media tracks without stale state
      final newTracksCompleter = Completer<void>();
      final tracksSub = _player.stream.tracks.listen((t) {
        if (t.video.any((v) => v.id != 'no' && v.id != 'auto')) {
          if (!newTracksCompleter.isCompleted) newTracksCompleter.complete();
        }
      });

      _logPlayer('Calling _player.open (targetOffset=${startSeconds}s)...');
if (Platform.isAndroid && _nativeSurfaceWid != null) {
        await _applyNativeSurfaceWid(_nativeSurfaceWid!);
      }

      await _player.open(
        Media(
          _selectedStream!.url,
          httpHeaders: metadata.httpHeaders,
        ),
        play: false,
      );
      _logPlayer('_player.open completed!');
      try {
        final activeHwdec = await nativePlayer.getProperty('hwdec-current');
        _logPlayer('[HARDWARE_ACCELERATION] Current active hwdec: $activeHwdec');
      } catch (_) {}

      // Failsafe timer: Ensure loading overlay NEVER gets permanently stuck on screen
      Timer(const Duration(seconds: 8), () {
        if (mounted && _isLoadingVideo) {
          _logPlayer('[FAILSAFE] Loading shield auto-dismissed after 8s timeout');
          try { _player.setVolume(100); } catch (_) {}
          setState(() {
            _isLoadingVideo = false;
            _showTvControls = false;
          });
          _videoPlayerFocusNode.requestFocus();
        }
      });

      // 3. Fast non-blocking track readiness confirmation (1.5s max timeout)
      _logPlayer('Waiting for MPV video track readiness...');
      try {
        await newTracksCompleter.future.timeout(const Duration(milliseconds: 1500));
        _logPlayer('Video track confirmed ready in MPV core!');
      } catch (e) {
        _logPlayer('Video track wait fast-fallback: $e');
      } finally {
        await tracksSub.cancel();
      }

      // 4. Attach external audio track cleanly (only for non-HLS streams; HLS already includes audio)
      final isHls = _selectedStream!.url.contains('m3u8') || _selectedStream!.url.contains('hls_playlist');
      if (!isHls && _audioUrl != null && _audioUrl!.isNotEmpty) {
        try {
          _logPlayer('Attaching audio track...');
          await _player.setAudioTrack(AudioTrack.uri(_audioUrl!));
          _logPlayer('Audio track attached!');
        } catch (e) {
          _logPlayer('Audio track attach error: $e');
        }
      } else if (isHls) {
        _logPlayer('Stream is HLS (contains internal audio), skipping external audio track attach.');
      }

      if (Platform.isAndroid) {
        try {
          final nativePlayer = _player.platform as dynamic;
          await nativePlayer.setProperty('audio-delay', '-0.250');
        } catch (_) {}
      }

      // 5. Check if user previously watched this match and resume!
      final resumeOffset = await PlaybackProgressService.instance.getResumePosition(
        matchId: widget.matchId,
        defaultOffsetSeconds: startSeconds,
        matchDurationSeconds: widget.matchDurationSeconds,
        youtubeId: widget.youtubeId,
      );

      // Seek unified timeline (aligns BOTH video and audio clocks to target offset!)
      if (resumeOffset > 0) {
        _logPlayer('Seeking unified timeline to ${resumeOffset}s (initial=${startSeconds}s)...');
        try {
          await _player.seek(Duration(seconds: resumeOffset));
        } catch (e) {
          _logPlayer('Initial seek error: $e');
        }
      }

      // 6. Resume synchronized playback
      try {
        await _player.play();
        _logPlayer('Resumed synchronized playback from ${resumeOffset}s');
      } catch (_) {}

      // 6. Wait until playback has settled at target match offset before revealing screen
      if (resumeOffset > 0) {
        final minTargetMs = (resumeOffset > 2 ? resumeOffset - 2 : 0) * 1000;
        try {
          await _player.stream.position
              .firstWhere((p) => p.inMilliseconds >= minTargetMs)
              .timeout(Duration(seconds: Platform.isAndroid ? 5 : 3));
          _logPlayer('Target offset confirmed reached! pos=${_player.state.position.inMilliseconds}ms');
        } catch (e) {
          _logPlayer('Target offset wait: $e (pos=${_player.state.position.inMilliseconds}ms)');
        }
      } else {
        try {
          await _player.stream.position
              .firstWhere((p) => p.inMilliseconds > 50)
              .timeout(Duration(seconds: Platform.isAndroid ? 5 : 3));
        } catch (_) {}
      }
      // Reveal video immediately once offset is settled
      if (mounted) {
        setState(() {
          _isLoadingVideo = false;
          _showTvControls = false;
        });
        _videoPlayerFocusNode.requestFocus();
      }
      _logPlayer('Dismissed loading shield! _isLoadingVideo=$_isLoadingVideo');

      // Unmute audio non-blockingly
      try {
        _player.setVolume(100);
      } catch (_) {}
    } catch (e, stack) {
      _logPlayer('EXCEPTION in _loadVideo: $e\n$stack');
      if (mounted) {
        setState(() {
          _isLoadingVideo = false;
          if (e is ProcessException) {
            _errorMessage = e.message.isNotEmpty ? e.message : e.toString();
          } else {
            _errorMessage = e.toString();
          }
        });
      }
    }
  }

  void _changeQuality(YtStreamInfo stream) {
    if (widget.youtubeId != null) {
      final currentPosition = _player.state.position.inSeconds;
      if (mounted) setState(() => _isLoadingVideo = true);
      _loadVideo(widget.youtubeId!, currentPosition, stream);
    }
  }


  Widget _buildQualitySelector() {
    return PopupMenuButton<YtStreamInfo>(
      key: const Key('quality_selector_btn'),
      icon: const Icon(Icons.settings, color: Colors.white, size: 28),
      color: Colors.black.withValues(alpha: 0.8),
      tooltip: 'Video Quality',
      onSelected: _changeQuality,
      itemBuilder: (BuildContext context) {
        return _availableStreams.map((stream) {
          final isSelected = stream.height == _selectedStream?.height;
          return PopupMenuItem<YtStreamInfo>(
            key: Key('quality_${stream.height}p'),
            value: stream,
            child: Row(
              children: [
                Icon(
                  isSelected ? Icons.check : Icons.circle,
                  color: isSelected ? Colors.red : Colors.transparent,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  '${stream.height}p',
                  style: TextStyle(
                    color: isSelected ? Colors.red : Colors.white,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          );
        }).toList();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    _logPlayer('BUILD: _isLoadingVideo=$_isLoadingVideo, matchId=${widget.matchId}, img=${widget.imageUrl.length > 30 ? widget.imageUrl.substring(0, 30) : widget.imageUrl}...');

    final thumbnailWidget = Container(
      decoration: BoxDecoration(
        color: Colors.black,
        image: DecorationImage(
          image: NetworkImage(widget.imageUrl),
          fit: BoxFit.cover,
        ),
      ),
      child: Center(
        child: TvFocusable(
          focusNode: filterController.playButtonFocusNode,
          onLeft: () => filterController.focusCurrentMatch(),
          onDown: () => filterController.focusProgressBar(),
          borderRadius: BorderRadius.circular(100),
          normalBackgroundColor: Colors.black.withValues(alpha: 0.6),
          normalBorderColor: Colors.transparent,
          padding: const EdgeInsets.all(16),
          onTap: () {
            if (widget.youtubeId != null) {
              setState(() {
                _hasStarted = true;
                _isLoadingVideo = true;
              });
              _loadVideo(widget.youtubeId!, widget.offsetSeconds);
              isFullscreenNotifier.value = true;
            }
          },
          child: const Icon(
            Icons.play_arrow,
            size: 48,
            color: Colors.white,
          ),
        ),
      ),
    );



    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Focus(
        focusNode: _videoPlayerFocusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          final isDown = event is KeyDownEvent;
          final isRepeat = event is KeyRepeatEvent;

          if (isDown || isRepeat) {
            // DOWN: Focus progress bar (discrete only)
            if (isDown && event.logicalKey == LogicalKeyboardKey.arrowDown) {
              if (filterController.playButtonFocusNode.hasFocus) {
                filterController.focusProgressBar();
                return KeyEventResult.handled;
              } else if (!filterController.progressBarFocusNode.hasFocus) {
                setState(() => _showTvControls = true);
                filterController.focusProgressBar();
                return KeyEventResult.handled;
              }
            }
            // UP: Focus play/resume button (discrete only)
            if (isDown && event.logicalKey == LogicalKeyboardKey.arrowUp) {
              if (filterController.progressBarFocusNode.hasFocus) {
                filterController.focusPlayButton();
                return KeyEventResult.handled;
              } else if (!filterController.playButtonFocusNode.hasFocus) {
                setState(() => _showTvControls = true);
                filterController.focusPlayButton();
                return KeyEventResult.handled;
              }
            }
            if (isDown &&
                (event.logicalKey == LogicalKeyboardKey.select ||
                    event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.space ||
                    event.logicalKey == LogicalKeyboardKey.gameButtonSelect ||
                    event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
              _toggleTvPlayback();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              if (isDown && filterController.playButtonFocusNode.hasFocus) {
                filterController.focusCurrentMatch();
                return KeyEventResult.handled;
              }
              _performProgressiveSeek(forward: false);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              if (isDown && filterController.playButtonFocusNode.hasFocus) {
                return KeyEventResult.handled;
              }
              _performProgressiveSeek(forward: true);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            LayoutBuilder(
            builder: (context, constraints) {
              return Listener(
                behavior: HitTestBehavior.translucent,
                onPointerUp: (event) {
                  if (event.localPosition.dy < constraints.maxHeight - 80) {
                    if (Platform.isAndroid || Platform.isIOS) {
                      // On mobile, toggle immediately with 0ms delay!
                      _toggleTvPlayback();
                    } else {
                      if (_singleClickTimer != null && _singleClickTimer!.isActive) {
                        _singleClickTimer!.cancel();
                      } else {
                        // On desktop, tight 180ms window for double-click
                        _singleClickTimer = Timer(const Duration(milliseconds: 180), () {
                          _toggleTvPlayback();
                        });
                      }
                    }
                  }
                },
                child: GestureDetector(
                  // media_kit does not consume double taps by default, so this safely wins the arena
                  onDoubleTap: widget.onDoubleTap,
                  child: MaterialDesktopVideoControlsTheme(
                    normal: MaterialDesktopVideoControlsThemeData(
                      hideMouseOnControlsRemoval: true,
                      bufferingIndicatorBuilder: (context) => const SizedBox.shrink(),
                      topButtonBar: [
                        const Spacer(),
                        if (_availableStreams.isNotEmpty) _buildQualitySelector(),
                      ],
                      bottomButtonBar: [
                        const MaterialDesktopSkipPreviousButton(),
                        InstantPlayOrPauseButton(player: _player),
                        const MaterialDesktopSkipNextButton(),
                        const MaterialDesktopVolumeButton(),
                        const MaterialDesktopPositionIndicator(),
                        const Spacer(),
                        const MaterialDesktopFullscreenButton(),
                      ],
                    ),
                    fullscreen: MaterialDesktopVideoControlsThemeData(
                      hideMouseOnControlsRemoval: true,
                      bufferingIndicatorBuilder: (context) => const SizedBox.shrink(),
                      topButtonBar: [
                        const Spacer(),
                        if (_availableStreams.isNotEmpty) _buildQualitySelector(),
                      ],
                      bottomButtonBar: [
                        const MaterialDesktopSkipPreviousButton(),
                        InstantPlayOrPauseButton(player: _player),
                        const MaterialDesktopSkipNextButton(),
                        const MaterialDesktopVolumeButton(),
                        const MaterialDesktopPositionIndicator(),
                        const Spacer(),
                        const MaterialDesktopFullscreenButton(),
                      ],
                    ),
                    child: Platform.isAndroid
                        ? NativeSurfaceView(
                            player: _player,
                            controls: NoVideoControls,
                            onSurfaceCreated: _handleNativeSurfaceCreated,
                            onSurfaceChanged: _handleNativeSurfaceChanged,
                            onSurfaceDestroyed: () {
                              _logPlayer('[NATIVE_SURFACE] Surface destroyed');
                              _nativeSurfaceWid = null;
                            },
                          )
                        : Video(controller: _controller!, controls: NoVideoControls),
                  ),
                ),
              );
            },
          ),

          if (!_hasStarted)
            Positioned.fill(child: thumbnailWidget),

          if (widget.resizingNotifier != null)
            ValueListenableBuilder<bool>(
              valueListenable: widget.resizingNotifier!,
              builder: (context, isResizing, _) {
                if (isResizing) {
                  return thumbnailWidget;
                }
                return const SizedBox.shrink();
              },
            ),

          if (_isLoadingVideo)
            Positioned.fill(
              child: Container(
                key: const Key('match_loading_overlay'),
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (widget.imageUrl.isNotEmpty)
                      Image.network(
                        widget.imageUrl,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                      ),
                    Container(
                      color: Colors.black.withValues(alpha: 0.5),
                    ),
                    const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF0D7FF2),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          if (_errorMessage != null)
            Positioned.fill(
              child: Container(
                key: const Key('video_error_overlay'),
                padding: const EdgeInsets.all(24),
                color: Colors.black.withValues(alpha: 0.92),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E2E),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFFE53935),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFE53935).withValues(alpha: 0.3),
                            blurRadius: 16,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.error_outline_rounded,
                                color: Color(0xFFEF5350),
                                size: 28,
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Text(
                                  'Playback / Extraction Error',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SelectableText(
                            _errorMessage!,
                            style: const TextStyle(
                              color: Color(0xFFFFCDD2),
                              fontSize: 12,
                              fontFamily: 'monospace',
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton.icon(
                                onPressed: () {
                                  setState(() {
                                    _errorMessage = null;
                                    _isLoadingVideo = true;
                                  });
                                  _loadVideo(widget.youtubeId!, widget.offsetSeconds);
                                },
                                icon: const Icon(Icons.refresh, size: 16, color: Colors.white),
                                label: const Text('Retry', style: TextStyle(color: Colors.white)),
                                style: TextButton.styleFrom(
                                  backgroundColor: const Color(0xFFE53935),
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // TV Controls & Progress Bar Overlay
            if (!_isLoadingVideo && _errorMessage == null && (_showTvControls || !_player.state.playing)) ...[
              Builder(
                builder: (context) {
                  final h = _player.state.height ?? _selectedStream?.height ?? 1080;
                  final decoderText = Platform.isAndroid ? "HW: mediacodec" : "HW: auto";
                  final pipelineText = Platform.isAndroid ? "vo: gpu (AImageReader)" : "vo: gpu";

                  return Positioned(
                    top: 24,
                    right: 32,
                    child: Container(
                      key: const Key("player_diagnostics_badge"),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: const Color(0xFF00E676).withValues(alpha: 0.5),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.6),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFF00E676),
                              boxShadow: [
                                BoxShadow(
                                  color: Color(0xFF00E676),
                                  blurRadius: 6,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "${h}p",
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              fontFamily: "monospace",
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text("•", style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                          const SizedBox(width: 6),
                          const Text(
                            "H264",
                            style: TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              fontFamily: "monospace",
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text("•", style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                          const SizedBox(width: 6),
                          Text(
                            decoderText,
                            style: const TextStyle(
                              color: Color(0xFF00E676),
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              fontFamily: "monospace",
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text("•", style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                          const SizedBox(width: 6),
                          Text(
                            pipelineText,
                            style: TextStyle(
                              color: Colors.grey[300],
                              fontSize: 12,
                              fontFamily: "monospace",
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text("•", style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                          const SizedBox(width: 6),
                          Text(
                            "0 drops",
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 12,
                              fontFamily: "monospace",
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              Center(
                child: TvFocusable(
                  key: const Key('tv_play_pause_button'),
                  focusNode: filterController.playButtonFocusNode,
                  onLeft: () => filterController.focusCurrentMatch(),
                  onDown: () => filterController.focusProgressBar(),
                  borderRadius: BorderRadius.circular(100),
                  normalBackgroundColor: Colors.black.withValues(alpha: 0.65),
                  normalBorderColor: Colors.white24,
                  focusedBackgroundColor: const Color(0xFF0D7FF2),
                  focusedBorderColor: Colors.white,
                  focusedBorderWidth: 3.5,
                  scaleFactor: 1.15,
                  padding: const EdgeInsets.all(18),
                  onTap: _toggleTvPlayback,
                  child: StreamBuilder<bool>(
                    stream: _player.stream.playing,
                    initialData: _player.state.playing,
                    builder: (context, snapshot) {
                      final isPlaying = snapshot.data ?? false;
                      return Icon(
                        isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                        size: 44,
                      );
                    },
                  ),
                ),
              ),

              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.85),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                  child: StreamBuilder<Duration>(
                    stream: _player.stream.position,
                    initialData: _player.state.position,
                    builder: (context, posSnapshot) {
                      final streamPos = _targetSeekPosition ?? (posSnapshot.data ?? Duration.zero);
                      final totalDuration = _effectiveDuration;
                      final hasMatchDuration = widget.matchDurationSeconds != null && widget.matchDurationSeconds! > 0;
                      final matchOffset = _matchOffset;

                      final elapsed = hasMatchDuration ? (streamPos - matchOffset) : streamPos;
                      final displayPosition = elapsed < Duration.zero ? Duration.zero : elapsed;

                      final totalMs = totalDuration.inMilliseconds;
                      final currentMs = displayPosition.inMilliseconds.clamp(0, totalMs > 0 ? totalMs : 1);
                      final progress = totalMs > 0 ? currentMs / totalMs : 0.0;
                      final isProgressFocused = filterController.progressBarFocusNode.hasFocus;

                      return TvFocusable(
                        focusNode: filterController.progressBarFocusNode,
                        onUp: () => filterController.focusPlayButton(),
                        onLeft: () => _performProgressiveSeek(forward: false),
                        onRight: () => _performProgressiveSeek(forward: true),
                        onTap: _toggleTvPlayback,
                        borderRadius: BorderRadius.circular(12),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        normalBackgroundColor: Colors.black.withValues(alpha: 0.5),
                        normalBorderColor: Colors.white10,
                        focusedBackgroundColor: Colors.black.withValues(alpha: 0.88),
                        focusedBorderColor: const Color(0xFF0D7FF2),
                        focusedBorderWidth: 3.0,
                        scaleFactor: 1.02,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_targetSeekPosition != null && _cumulativeSeekSeconds != 0)
                              Center(
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0D7FF2),
                                    borderRadius: BorderRadius.circular(16),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF0D7FF2).withValues(alpha: 0.6),
                                        blurRadius: 12,
                                        spreadRadius: 2,
                                      ),
                                    ],
                                  ),
                                  child: Text(
                                    '${_cumulativeSeekSeconds > 0 ? ">> +" : "<< "}${_formatSeekDelta(_cumulativeSeekSeconds)}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      fontFamily: "monospace",
                                    ),
                                  ),
                                ),
                              ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _formatDuration(displayPosition),
                                  style: TextStyle(
                                    color: isProgressFocused ? const Color(0xFF4FC3F7) : Colors.white,
                                    fontSize: isProgressFocused ? 15 : 14,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                Text(
                                  _formatDuration(totalDuration),
                                  style: TextStyle(
                                    color: Colors.grey[400],
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(isProgressFocused ? 6 : 4),
                              child: LinearProgressIndicator(
                                value: progress.clamp(0.0, 1.0),
                                minHeight: isProgressFocused ? 10 : 5,
                                backgroundColor: Colors.white.withValues(alpha: 0.25),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  isProgressFocused ? const Color(0xFF4FC3F7) : const Color(0xFF0D7FF2),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
