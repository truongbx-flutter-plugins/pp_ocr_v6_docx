import 'dart:ui';

class OcrResult {
  const OcrResult({
    required this.text,
    required this.confidence,
    required this.points,
    this.isUpsideDown,
    this.angleConfidence,
  });

  /// Recognized string.
  final String text;

  /// Recognition confidence in `[0, 1]`.
  final double confidence;

  /// Polygon (usually 4 points) bounding the text in source-image pixels.
  final List<Offset> points;

  /// `true` if the text was detected as upside-down (180°). Null when angle
  /// classification was not run.
  final bool? isUpsideDown;

  /// Confidence of the angle classification, if run.
  final double? angleConfidence;

  factory OcrResult.fromMap(Map<dynamic, dynamic> map) {
    final rawPoints = (map['points'] as List?) ?? const [];
    return OcrResult(
      text: map['text'] as String? ?? '',
      confidence: (map['confidence'] as num?)?.toDouble() ?? 0,
      points: rawPoints
          .cast<List<dynamic>>()
          .map(
            (p) => Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
      )
          .toList(growable: false),
      isUpsideDown: map['isUpsideDown'] as bool?,
      angleConfidence: (map['angleConfidence'] as num?)?.toDouble(),
    );
  }

  @override
  String toString() =>
      'OcrResult("$text", confidence: ${confidence.toStringAsFixed(3)}, '
          'points: $points)';
}
