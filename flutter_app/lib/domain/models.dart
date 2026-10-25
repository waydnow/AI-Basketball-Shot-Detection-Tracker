/// Persisted, user-editable entities. The detector's own types live in `shot_logic.dart`
/// and are deliberately separate: a `Shot` is what the user sees on the timeline after they
/// may have moved, added or disabled it, and it must survive re-running detection.
library;

class Video {
  const Video({
    required this.id,
    required this.uri,
    required this.durationUs,
    this.fps,
    this.width = 0,
    this.height = 0,
    this.analyzedAt,
  });

  factory Video.fromRow(Map<String, Object?> row) => Video(
        id: row['id'] as String,
        uri: row['uri'] as String,
        durationUs: (row['duration_us'] as int?) ?? 0,
        fps: (row['fps'] as num?)?.toDouble(),
        width: (row['width'] as int?) ?? 0,
        height: (row['height'] as int?) ?? 0,
        analyzedAt: row['analyzed_at'] as int?,
      );

  final String id;
  final String uri;
  final int durationUs;

  /// Null until on-device analysis fills it in; `video_player` cannot report it.
  final double? fps;
  final int width;
  final int height;

  /// Set the first time auto detection wrote its events. A second run must not
  /// overwrite markers the user has since moved.
  final int? analyzedAt;

  bool get analyzed => analyzedAt != null;

  /// The player knows the real geometry only after it has opened the file.
  Video withMeta({required int durationUs, int? width, int? height}) => Video(
        id: id,
        uri: uri,
        durationUs: durationUs,
        fps: fps,
        width: width ?? this.width,
        height: height ?? this.height,
        analyzedAt: analyzedAt,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'uri': uri,
        'duration_us': durationUs,
        'fps': fps,
        'width': width,
        'height': height,
        'analyzed_at': analyzedAt,
      };
}

enum ShotOrigin { auto, manual }

class Shot {
  const Shot({
    this.id,
    required this.videoId,
    required this.tUs,
    required this.isMake,
    required this.origin,
    required this.windowBeforeUs,
    required this.windowAfterUs,
    this.enabled = true,
  });

  factory Shot.fromRow(Map<String, Object?> row) => Shot(
        id: row['id'] as int?,
        videoId: row['video_id'] as String,
        tUs: row['t_us'] as int,
        isMake: (row['is_make'] as int) != 0,
        origin: ShotOrigin.values.byName(row['origin'] as String),
        windowBeforeUs: row['window_before_us'] as int,
        windowAfterUs: row['window_after_us'] as int,
        enabled: (row['enabled'] as int) != 0,
      );

  final int? id;
  final String videoId;

  /// The moment marked on the timeline: the ball dropping below the net.
  final int tUs;
  final bool isMake;
  final ShotOrigin origin;
  final int windowBeforeUs;
  final int windowAfterUs;
  final bool enabled;

  /// Any change of time or window is a user edit, so the pin switches to the
  /// "manual" colour and re-running detection will never reset it.
  bool get manual => origin == ShotOrigin.manual;

  Shot copyWith({
    int? tUs,
    bool? isMake,
    ShotOrigin? origin,
    int? windowBeforeUs,
    int? windowAfterUs,
    bool? enabled,
  }) =>
      Shot(
        id: id,
        videoId: videoId,
        tUs: tUs ?? this.tUs,
        isMake: isMake ?? this.isMake,
        origin: origin ?? this.origin,
        windowBeforeUs: windowBeforeUs ?? this.windowBeforeUs,
        windowAfterUs: windowAfterUs ?? this.windowAfterUs,
        enabled: enabled ?? this.enabled,
      );

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'video_id': videoId,
        't_us': tUs,
        'is_make': isMake ? 1 : 0,
        'origin': origin.name,
        'window_before_us': windowBeforeUs,
        'window_after_us': windowAfterUs,
        'enabled': enabled ? 1 : 0,
      };
}

/// A span to cut out of the source video, clamped to what actually exists.
class Segment {
  const Segment({required this.shot, required this.startUs, required this.endUs});

  final Shot shot;
  final int startUs;
  final int endUs;

  int get durationUs => endUs - startUs;
}

/// The cut list the export step will feed to ffmpeg: disabled pins drop out, misses drop
/// out when the user asked for makes only, and a pin near the start or end of the clip is
/// clamped instead of producing a segment that runs past the video.
List<Segment> planSegments({
  required List<Shot> shots,
  required int durationUs,
  required bool includeMisses,
}) {
  final sorted = [...shots.where((s) => s.enabled && (includeMisses || s.isMake))]
    ..sort((a, b) => a.tUs.compareTo(b.tUs));
  return [
    for (final s in sorted)
      Segment(
        shot: s,
        startUs: (s.tUs - s.windowBeforeUs).clamp(0, durationUs),
        endUs: (s.tUs + s.windowAfterUs).clamp(0, durationUs),
      ),
  ];
}

/// The file name as the user would recognise it, decoded back from whatever the Android
/// content provider escaped it to.
String clipLabel(String uri) {
  final name = uri.split('/').last;
  return Uri.decodeComponent(name.length > 40 ? '${name.substring(0, 40)}…' : name);
}

String formatUs(int us) {
  final total = us / 1000000;
  final m = (total / 60).floor();
  final s = total - m * 60;
  return '${m.toString().padLeft(2, '0')}:${s.toStringAsFixed(1).padLeft(4, '0')}';
}
