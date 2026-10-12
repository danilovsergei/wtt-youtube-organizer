import 'package:flutter/material.dart';
import 'video_player_desktop.dart' if (dart.library.html) 'video_player_web.dart' as impl;

abstract class VideoPlayerWidget extends StatefulWidget {
  final ValueNotifier<bool>? resizingNotifier;
  final String? matchId;
  final String? youtubeId;
  final String imageUrl;
  final int offsetSeconds;
  final int? matchDurationSeconds;
  final void Function() onDoubleTap;
  final bool autoPlay;

  const VideoPlayerWidget({
    super.key,
    this.resizingNotifier,
    required this.matchId,
    required this.youtubeId,
    required this.imageUrl,
    required this.offsetSeconds,
    this.matchDurationSeconds,
    required this.onDoubleTap,
    this.autoPlay = true,
  });

  factory VideoPlayerWidget.create({
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
    return impl.createVideoPlayer(
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
}

