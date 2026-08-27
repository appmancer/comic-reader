/// Sidecar geometry produced by the Python pipeline (see ../../cg/).
///
/// Deliberately stores *geometry*, not finished beats: panels and balloons in
/// normalised page coordinates. Beats are computed at read time for the actual
/// screen, so one analysis serves phone and tablet, portrait and landscape.
library;

import 'dart:convert';

/// Normalised rect. All values 0..1 relative to page width/height.
class NRect {
  final double l, t, r, b;
  const NRect(this.l, this.t, this.r, this.b);

  double get w => r - l;
  double get h => b - t;
  double get area => w * h;
  double get cx => (l + r) / 2;
  double get cy => (t + b) / 2;

  factory NRect.fromJson(List<dynamic> j) =>
      NRect((j[0] as num).toDouble(), (j[1] as num).toDouble(),
            (j[2] as num).toDouble(), (j[3] as num).toDouble());

  List<double> toJson() => [l, t, r, b];

  NRect union(NRect o) => NRect(
      l < o.l ? l : o.l, t < o.t ? t : o.t,
      r > o.r ? r : o.r, b > o.b ? b : o.b);

  /// Area of overlap with [o], in normalised units.
  double overlap(NRect o) {
    final ow = (r < o.r ? r : o.r) - (l > o.l ? l : o.l);
    final oh = (b < o.b ? b : o.b) - (t > o.t ? t : o.t);
    return (ow <= 0 || oh <= 0) ? 0 : ow * oh;
  }

  /// Fraction of [o] that lies inside this rect (0..1).
  double fractionOf(NRect o) => o.area <= 0 ? 0 : overlap(o) / o.area;

  NRect clampTo(NRect bound) => NRect(
      l < bound.l ? bound.l : l, t < bound.t ? bound.t : t,
      r > bound.r ? bound.r : r, b > bound.b ? bound.b : b);

  @override
  String toString() => '[${l.toStringAsFixed(3)},${t.toStringAsFixed(3)},'
      '${r.toStringAsFixed(3)},${b.toStringAsFixed(3)}]';
}

/// One speech balloon or caption. [panel] indexes into [PageGuide.panels].
class Balloon {
  final NRect rect;
  final int panel;

  /// Height of a line of lettering, normalised to page height. Drives the
  /// read-time zoom: we scale so this lands at a legible size on screen.
  final double lineHeight;

  const Balloon({required this.rect, required this.panel, this.lineHeight = 0});

  factory Balloon.fromJson(Map<String, dynamic> j) => Balloon(
        rect: NRect.fromJson(j['rect'] as List),
        panel: (j['panel'] as num?)?.toInt() ?? 0,
        lineHeight: (j['line_height'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() =>
      {'rect': rect.toJson(), 'panel': panel, 'line_height': lineHeight};
}

/// A panel. Order is the index in the list — the Python side emits them in
/// reading order from an X-Y cut tree traversal, which is load-bearing:
/// a full-height left column must read entirely before the right-hand panels.
class Panel {
  final NRect rect;
  const Panel(this.rect);

  factory Panel.fromJson(Map<String, dynamic> j) =>
      Panel(NRect.fromJson(j['rect'] as List));

  Map<String, dynamic> toJson() => {'rect': rect.toJson()};
}

class PageGuide {
  final int index;
  final List<Panel> panels;
  final List<Balloon> balloons;

  /// Analyser's own confidence. Below ~0.5 the reader should fall back to
  /// showing the whole page rather than guiding badly.
  final double confidence;

  const PageGuide({
    required this.index,
    required this.panels,
    required this.balloons,
    this.confidence = 1.0,
  });

  factory PageGuide.fromJson(Map<String, dynamic> j) => PageGuide(
        index: (j['index'] as num).toInt(),
        panels: (j['panels'] as List? ?? [])
            .map((p) => Panel.fromJson(p as Map<String, dynamic>))
            .toList(),
        balloons: (j['balloons'] as List? ?? [])
            .map((b) => Balloon.fromJson(b as Map<String, dynamic>))
            .toList(),
        confidence: (j['confidence'] as num?)?.toDouble() ?? 1.0,
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'panels': panels.map((p) => p.toJson()).toList(),
        'balloons': balloons.map((b) => b.toJson()).toList(),
        'confidence': confidence,
      };
}

class Guide {
  static const int currentVersion = 1;

  final int version;
  final String sourceId;
  final int pageCount;
  final Map<int, PageGuide> pages;

  const Guide({
    required this.version,
    required this.sourceId,
    required this.pageCount,
    required this.pages,
  });

  PageGuide? page(int i) => pages[i];

  factory Guide.fromJson(Map<String, dynamic> j) {
    final pages = <int, PageGuide>{};
    for (final p in (j['pages'] as List? ?? [])) {
      final pg = PageGuide.fromJson(p as Map<String, dynamic>);
      pages[pg.index] = pg;
    }
    return Guide(
      version: (j['version'] as num?)?.toInt() ?? 1,
      sourceId: j['source_id'] as String? ?? '',
      pageCount: (j['page_count'] as num?)?.toInt() ?? pages.length,
      pages: pages,
    );
  }

  static Guide? tryParse(String s) {
    try {
      return Guide.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'source_id': sourceId,
        'page_count': pageCount,
        'pages': pages.values.map((p) => p.toJson()).toList(),
      };
}
