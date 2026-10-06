class YtStreamInfo {
  final int height;
  final String url;

  const YtStreamInfo(this.height, this.url);

  @override
  String toString() => '${height}p ($url)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is YtStreamInfo &&
          runtimeType == other.runtimeType &&
          height == other.height &&
          url == other.url;

  @override
  int get hashCode => height.hashCode ^ url.hashCode;
}

class VideoStreamMetadata {
  final List<YtStreamInfo> videoStreams;
  final String? audioUrl;
  final Map<String, String> httpHeaders;
  final Map<String, dynamic>? rawManifest;

  const VideoStreamMetadata({
    required this.videoStreams,
    this.audioUrl,
    this.httpHeaders = const {},
    this.rawManifest,
  });

  List<int> get availableResolutions =>
      videoStreams.map((s) => s.height).toList();
}
