/// Turns page geometry into an ordered sequence of beats, for THIS screen.
///
/// Beats are computed at read time rather than stored, so one analysis serves
/// phone and tablet, portrait and landscape. The binding constraint is not
/// "a quarter of the page" but whether the lettering ends up legible: Panels'
/// visible failure on a small screen is beats that are too loose to read.
///
/// Rules settled against Savage Dragon #1 p13 and 2000AD Absalom:
///   - forward bleed into unread balloons  <= 20% of the balloon visible
///   - backward bleed into read balloons   <= 12%
///   - the beat's own panel                >= 50% of the beat area
///   - overlap with already-shown area     <= 25%
///   - bleed forward, never backward
library;

import 'dart:math' as math;
import 'dart:ui' show Size;

import '../model/guide.dart';

class Beat {
  /// Region of the page to show, normalised.
  final NRect rect;

  /// Indices into [PageGuide.balloons] that this beat exists to show.
  final List<int> balloons;

  /// True when this beat covers art with no dialogue. Inserted so the reader
  /// never skips part of the page.
  final bool isArt;

  /// The panel rectangles this beat is actually about. The renderer masks
  /// everything else in the frame to the page's border colour, so a beat can
  /// be framed generously without a neighbouring panel competing for
  /// attention - which is what caused most of the "bleeds into the pane below"
  /// complaints.
  final List<NRect> focus;

  const Beat({
    required this.rect,
    required this.balloons,
    this.isArt = false,
    this.focus = const [],
  });

  @override
  String toString() =>
      'Beat($rect, balloons=$balloons${isArt ? ', art' : ''})';
}

class BeatPlanner {
  /// Target height of a line of lettering, in logical pixels. Below roughly 11
  /// it stops being comfortable; this is the knob a "text size" setting turns.
  final double minLineHeightPx;

  /// Largest share of the page a MERGED beat may cover. A single panel is
  /// always allowed to be a beat on its own, however big it is - splitting a
  /// panel across beats reads badly.
  final double maxBeatArea;

  /// A beat must magnify to earn its place. Gain is its displayed scale over
  /// the whole-page scale; below this we slice it, because a beat that shows
  /// the reader the same size they already had is a wasted tap.
  ///
  /// This is what distinguishes a full-height column - scale-limited by height,
  /// so gain ~1.5 no matter how narrow it is - from an ordinary panel, which
  /// already lands around 3.5x and must NOT be sliced.
  final double minGain;

  /// EXPERIMENTAL. When true, an art beat (no dialogue) whose edge detail is
  /// well below the page median is merged into a neighbour instead of claiming
  /// a tap of its own. Unvalidated - it measures texture, not importance, and
  /// would discard a deliberately empty panel. Off by default.
  final bool useDetail;

  /// Target number of focus points per page.
  final int targetMin;
  final int targetMax;

  /// Caps, as fractions of an individual balloon's area.
  final double forwardBleed;
  final double backwardBleed;
  final double minOwnPanelShare;
  final double maxRepeatShare;

  const BeatPlanner({
    this.minLineHeightPx = 13.0,
    this.maxBeatArea = 0.34,
    this.minGain = 2.0,
    this.useDetail = false,
    this.targetMin = 4,
    this.targetMax = 6,
    this.forwardBleed = 0.20,
    this.backwardBleed = 0.12,
    this.minOwnPanelShare = 0.50,
    this.maxRepeatShare = 0.25,
  });

  /// Scale at which [rect] would be displayed in [viewport], given the page
  /// renders at [pagePx]. Letterboxed fit — we accept black bars by design.
  double _scaleFor(NRect rect, Size viewport, Size pagePx) {
    final w = rect.w * pagePx.width;
    final h = rect.h * pagePx.height;
    if (w <= 0 || h <= 0) return 0;
    return math.min(viewport.width / w, viewport.height / h);
  }

  /// A tall, narrow region can never magnify: its scale is pinned by height.
  bool _tallAndNarrow(NRect r) => r.h >= 0.75 && r.w <= 0.55;

  /// Magnification of [rect] relative to viewing the whole page.
  double _gain(NRect rect, Size viewport, Size pagePx) {
    final pageScale = math.min(
        viewport.width / pagePx.width, viewport.height / pagePx.height);
    if (pageScale <= 0) return 1;
    return _scaleFor(rect, viewport, pagePx) / pageScale;
  }

  /// Does [rect] keep every balloon in [focus] readable?
  bool _legible(NRect rect, List<Balloon> focus, Size viewport, Size pagePx) {
    if (focus.isEmpty) return true;
    final scale = _scaleFor(rect, viewport, pagePx);
    for (final b in focus) {
      // Below ~0.9% of page height is not lettering, it is noise in the
      // measurement. Treating it as real forced needlessly tight beats.
      if (b.lineHeight < 0.009) continue;
      if (b.lineHeight * pagePx.height * scale < minLineHeightPx) return false;
    }
    return true;
  }

  List<Beat> plan(PageGuide page, Size viewport, Size pagePx) {
    if (page.panels.isEmpty) return const [];

    // Balloons grouped by owning panel, panels already in reading order.
    final byPanel = <int, List<int>>{};
    for (var i = 0; i < page.balloons.length; i++) {
      byPanel.putIfAbsent(page.balloons[i].panel, () => []).add(i);
    }

    // 1. Splash pages have no panels: one image with narration floating over
    //    it (Savage Dragon #1 p15). The detector still reports "panels", but
    //    they are boundaries between blocks of text on black, so grouping by
    //    them puts nine captions in one 62%-of-page beat. Detect the shape and
    //    build units from the caption rows instead.
    // When layout detection collapses (one "panel" for the whole page) the
    // panel structure is worthless, but the balloons usually are not. Reading
    // by text rows beats refusing to guide at all.
    final splashUnits = _splashUnits(page, viewport, pagePx);
    if (splashUnits != null) {
      // Route through the same grouping as everything else so the beat count
      // lands in the 4-6 target instead of one beat per caption row.
      var g = _bestGrouping(splashUnits, page, viewport, pagePx);
      g = _mergeAdjacent(g, splashUnits, page, viewport, pagePx);
      final merged = <_Unit>[];
      for (final grp in g) {
        final rect =
            grp.map((i) => splashUnits[i].rect).reduce((a, b) => a.union(b));
        final balloons = <int>[];
        for (final i in grp) {
          balloons.addAll(splashUnits[i].balloons);
        }
        merged.add(_Unit(splashUnits[grp.first].panel, rect, balloons));
      }
      return _finish(merged, page, viewport, pagePx);
    }

    // 1. One unit per panel. A panel is only split when showing it whole
    //    would not magnify - a full-height column fills the screen but leaves
    //    the reader no better off than looking at the page. Ordinary panels
    //    already clear minGain comfortably and stay intact, which is what
    //    stops us slicing a face into an eye, a mouth and a shoulder.
    final units = <_Unit>[];
    for (var pi = 0; pi < page.panels.length; pi++) {
      final rect = page.panels[pi].rect;
      final ids = byPanel[pi] ?? const <int>[];
      // Only tall panels. A full-width panel also scores gain ~1 on a portrait
      // screen, but slicing it left/right cuts the composition in half - the
      // page was laid out to be read at that width. A column was not.
      final tallPanel = rect.h * pagePx.height > rect.w * pagePx.width * 1.2;
      final gain = _gain(rect, viewport, pagePx);
      var k = 1;
      if (tallPanel && gain < minGain) {
        k = math.min(3, (minGain / math.max(gain, 0.01)).ceil());
      }
      // A slice boundary must not cut a balloon in half either.
      if (k > 1) {
        for (var i = 1; i < k && k > 1; i++) {
          final cut = rect.t + rect.h * i / k;
          for (final j in ids) {
            final r = page.balloons[j].rect;
            if (r.t < cut && r.b > cut) {
              k = 1;
              break;
            }
          }
        }
      }
      if (k <= 1) {
        units.addAll(_splitByDialogue(_Unit(pi, rect, ids), page, viewport, pagePx));
        continue;
      }
      for (var i = 0; i < k; i++) {
        final part = NRect(rect.l, rect.t + rect.h * i / k, rect.r,
            rect.t + rect.h * (i + 1) / k);
        units.add(_Unit(
            pi,
            part,
            ids
                .where((j) =>
                    page.balloons[j].rect.cx >= part.l &&
                    page.balloons[j].rect.cx <= part.r &&
                    page.balloons[j].rect.cy >= part.t &&
                    page.balloons[j].rect.cy <= part.b)
                .toList()));
      }
    }

    // 1b. Absorb sliver panels into a neighbour. A 1.5%-of-page strip is
    //     detector noise and should never become a focus point of its own.
    const minUnitArea = 0.03;
    for (var i = units.length - 1; i >= 0 && units.length > 1; i--) {
      if (units[i].rect.area >= minUnitArea) continue;
      // Absorb only into a neighbour it tiles with. A bounding-box union
      // swallows a third panel and produces beats nested inside each other.
      final j = _tilingNeighbour(units, i);
      if (j < 0) continue;
      units[j] = _Unit(units[j].panel, units[j].rect.union(units[i].rect),
          [...units[j].balloons, ...units[i].balloons]);
      units.removeAt(i);
    }

    // 2. Group consecutive units into 4-6 beats, balanced by area. A greedy
    //    merge takes as many as fit and strands the remainder, which is how
    //    four equal panels became 3 + 1 instead of 2 + 2.
    var grouped = _bestGrouping(units, page, viewport, pagePx);
    grouped = _mergeAdjacent(grouped, units, page, viewport, pagePx);
    if (useDetail) grouped = _dropDullArt(grouped, units, page);

    final merged = <_Unit>[];
    for (final g in grouped) {
      final rect = g
          .map((i) => units[i].rect)
          .reduce((a, b) => a.union(b));
      final balloons = <int>[];
      for (final i in g) {
        balloons.addAll(units[i].balloons);
      }
      merged.add(_Unit(units[g.first].panel, rect, balloons));
    }

    return _finish(merged, page, viewport, pagePx);
  }

  List<Beat> _finish(List<_Unit> merged, PageGuide page, Size viewport,
      Size pagePx) {
    // 3. Expand each beat toward the viewport shape, honouring the bleed caps.
    final beats = <Beat>[];
    final shown = <NRect>[];
    final seen = <int>{};
    for (final u in merged) {
      // Balloons are assigned to a panel by their centre, so one can overflow
      // the panel it belongs to. The beat must still show it whole.
      var base = u.rect;
      for (final i in u.balloons) {
        base = base.union(page.balloons[i].rect);
      }
      final unit = _Unit(u.panel, base, u.balloons, keepApart: u.keepApart);
      final rect = _expand(page, unit, viewport, pagePx, shown, seen);
      // A beat almost entirely inside one already shown adds nothing.
      // A beat that mostly repeats one already shown adds nothing. Art beats
      // are held to a tighter bar than dialogue: page 14 had a 70%-repeat beat
      // carrying no dialogue at all.
      var repeated = 0.0;
      for (final s in shown) {
        repeated += s.overlap(rect);
      }
      final share = repeated / math.max(rect.area, 1e-9);
      final addsNothing = u.balloons.isEmpty || u.balloons.every(seen.contains);
      if (addsNothing && share > (u.balloons.isEmpty ? 0.55 : 0.85)) continue;

      beats.add(Beat(
        rect: rect,
        balloons: u.balloons,
        isArt: u.balloons.isEmpty,
        focus: [u.rect],
      ));
      shown.add(rect);
      seen.addAll(u.balloons);
      for (var i = 0; i < page.balloons.length; i++) {
        if (rect.fractionOf(page.balloons[i].rect) > 0.85) seen.add(i);
      }
    }
    return _coverPanels(beats, page, viewport, pagePx);
  }

  /// No part of the page may be skipped. A panel no beat reaches is folded
  /// into the nearest beat, or becomes its own if it will not fit.
  List<Beat> _coverPanels(
      List<Beat> beats, PageGuide page, Size viewport, Size pagePx) {
    if (beats.isEmpty) return beats;
    // When layout collapsed there is one "panel" covering the page; covering it
    // just adds a whole-page beat, which is worse than the gap it fixes.
    if (page.confidence < 0.5 || page.panels.length <= 1) return beats;
    final out = List<Beat>.from(beats);
    for (final panel in page.panels) {
      if (panel.rect.area < 0.045 || panel.rect.area > 0.6) continue;
      // Coverage is the UNION of all beats, not the best single one: a column
      // deliberately split into two beats is covered by neither alone, and
      // measuring per-beat re-added it whole as a third.
      var hit = 0, total = 0;
      for (var gy = 0; gy < 8; gy++) {
        for (var gx = 0; gx < 8; gx++) {
          final px = panel.rect.l + panel.rect.w * (gx + 0.5) / 8;
          final py = panel.rect.t + panel.rect.h * (gy + 0.5) / 8;
          total++;
          for (final b in out) {
            if (px >= b.rect.l && px <= b.rect.r &&
                py >= b.rect.t && py <= b.rect.b) {
              hit++;
              break;
            }
          }
        }
      }
      if (hit / total >= 0.6) continue;

      var target = -1;
      var nearest = double.infinity;
      for (var i = 0; i < out.length; i++) {
        if (out[i].rect.union(panel.rect).area > maxBeatArea) continue;
        final d = (out[i].rect.cy - panel.rect.cy).abs() +
            (out[i].rect.cx - panel.rect.cx).abs();
        if (d < nearest) {
          nearest = d;
          target = i;
        }
      }
      if (target >= 0) {
        out[target] = Beat(
          rect: out[target].rect.union(panel.rect),
          balloons: out[target].balloons,
          isArt: out[target].isArt,
          focus: [...out[target].focus, panel.rect],
        );
      } else {
        // Insert in reading position rather than re-sorting the whole list:
        // a global sort reordered two correct beats whose centres straddled a
        // band boundary.
        var at = out.length;
        for (var i = 0; i < out.length; i++) {
          if (out[i].rect.cy > panel.rect.cy + 0.05 ||
              (out[i].rect.cy > panel.rect.cy - 0.05 &&
                  out[i].rect.cx > panel.rect.cx)) {
            at = i;
            break;
          }
        }
        out.insert(at, Beat(
            rect: panel.rect, balloons: const [], isArt: true,
            focus: [panel.rect]));
      }
    }
    return out;
  }

  int _tilingNeighbour(List<_Unit> units, int i) {
    const eps = 0.004;
    final a = units[i].rect;
    for (var j = 0; j < units.length; j++) {
      if (j == i) continue;
      final b = units[j].rect;
      final alignedV = (a.t - b.t).abs() <= eps && (a.b - b.b).abs() <= eps;
      final alignedH = (a.l - b.l).abs() <= eps && (a.r - b.r).abs() <= eps;
      if (alignedV && ((a.l - b.r).abs() <= eps || (a.r - b.l).abs() <= eps)) return j;
      if (alignedH && ((a.t - b.b).abs() <= eps || (a.b - b.t).abs() <= eps)) return j;
    }
    return -1;
  }

  /// A wide panel holding two well-separated groups of dialogue is two beats.
  /// One character speaks on the left, another on the right - showing them
  /// together wastes the zoom and reads as one moment when it is two.
  List<_Unit> _splitByDialogue(_Unit u, PageGuide page, Size viewport,
      Size pagePx) {
    if (u.balloons.length < 2) return [u];
    // Genuinely wide. Savage Dragon #1 p13's face panel is only 1.03x wider
    // than tall and reads as one moment; issue 100's are nearer 2x.
    final wide = u.rect.w * pagePx.width > u.rect.h * pagePx.height * 1.65;
    if (!wide) return [u];

    final xs = u.balloons.map((i) => page.balloons[i].rect).toList()
      ..sort((a, b) => a.cx.compareTo(b.cx));
    // Widest horizontal gap between consecutive balloons.
    var gap = 0.0;
    var at = -1.0;
    for (var i = 0; i < xs.length - 1; i++) {
      final g = xs[i + 1].l - xs[i].r;
      if (g > gap) {
        gap = g;
        at = (xs[i].r + xs[i + 1].l) / 2;
      }
    }
    // Must be a real gap, and leave dialogue on both sides. Balloons often
    // overlap in x, so most gaps are negative; a clearly positive one is the
    // boundary between two speakers. Page 8 needed 5% of panel width.
    if (gap < 0.04 * u.rect.w || gap < 0.02 ||
        at <= u.rect.l + 0.15 * u.rect.w ||
        at >= u.rect.r - 0.15 * u.rect.w) {
      return [u];
    }
    // Never cut a balloon in half. Assignment is by centre, so a wide balloon
    // whose centre sits on one side can still straddle the split.
    for (final i in u.balloons) {
      final r = page.balloons[i].rect;
      if (r.l < at && r.r > at) return [u];
    }
    final left = NRect(u.rect.l, u.rect.t, at, u.rect.b);
    final right = NRect(at, u.rect.t, u.rect.r, u.rect.b);
    List<int> inRect(NRect r) => u.balloons
        .where((i) => page.balloons[i].rect.cx >= r.l && page.balloons[i].rect.cx <= r.r)
        .toList();
    final lb = inRect(left), rb = inRect(right);
    if (lb.isEmpty || rb.isEmpty) return [u];
    return [
      _Unit(u.panel, left, lb, keepApart: true),
      _Unit(u.panel, right, rb, keepApart: true),
    ];
  }

  /// Contiguous partitions of [units] into k groups, for k in the target
  /// range; pick the k and partition with the lowest cost.
  List<List<int>> _bestGrouping(
      List<_Unit> units, PageGuide page, Size viewport, Size pagePx) {
    final n = units.length;
    if (n <= 1) return [for (var i = 0; i < n; i++) [i]];

    final kLo = math.min(targetMin, n);
    final kHi = math.min(targetMax, n);

    // Legibility picks k, balance picks the partition within it. Fighting
    // balance inside a fixed k produced 3+1 groupings; letting it raise k
    // instead gives smaller beats, which is what actually buys legibility.
    List<List<int>>? bestLegible, bestAny;
    var costLegible = double.infinity, costAny = double.infinity;

    for (var k = kLo; k <= kHi; k++) {
      final part = _partition(units, k, page, viewport, pagePx);
      if (part == null) continue;
      final cost = _partitionCost(units, part, page, viewport, pagePx);
      if (cost < costAny) {
        costAny = cost;
        bestAny = part;
      }
      if (_allLegible(units, part, page, viewport, pagePx) && cost < costLegible) {
        costLegible = cost;
        bestLegible = part;
      }
    }
    return bestLegible ?? bestAny ?? [for (var i = 0; i < n; i++) [i]];
  }

  /// Merge neighbouring groups that are contiguous and still fit. Choosing k
  /// for legibility can leave two small adjacent beats that would sit happily
  /// in one frame - there is no reason to make the reader tap twice for them.
  List<List<int>> _mergeAdjacent(List<List<int>> groups, List<_Unit> units,
      PageGuide page, Size viewport, Size pagePx) {
    var out = groups.map((g) => List<int>.from(g)).toList();
    var changed = true;
    while (changed && out.length > targetMin) {
      changed = false;
      var bestI = -1;
      var bestArea = double.infinity;
      for (var i = 0; i < out.length - 1; i++) {
        final a = out[i], b = out[i + 1];
        if (b.first != a.last + 1) continue; // not contiguous in reading order
        if ([...a, ...b].any((i) => units[i].keepApart)) continue;
        final rect = _unionOf(units, a.first, b.last + 1);
        if (rect.area > maxBeatArea) continue;
        // Never merge back into a full-height column.
        if (_tallAndNarrow(rect)) continue;
        final focus = [
          for (final i2 in [...a, ...b])
            ...units[i2].balloons.map((j) => page.balloons[j])
        ];
        if (!_legible(rect, focus, viewport, pagePx)) continue;
        if (rect.area < bestArea) {
          bestArea = rect.area;
          bestI = i;
        }
      }
      if (bestI >= 0) {
        out[bestI] = [...out[bestI], ...out[bestI + 1]];
        out.removeAt(bestI + 1);
        changed = true;
      }
    }
    return out;
  }

  /// If one "panel" swamps the page while holding several captions, it is not
  /// a panel. Returns caption-row units, or null when this is a normal page.
  List<_Unit>? _splashUnits(PageGuide page, Size viewport, Size pagePx) {
    if (page.balloons.length < 3) return null;
    var dominant = -1;
    for (var i = 0; i < page.panels.length; i++) {
      if (page.panels[i].rect.area > 0.5) dominant = i;
    }
    // Also take this path when the analyser flagged the layout as unreliable.
    if (dominant < 0 && page.confidence >= 0.5) return null;
    if (dominant < 0) dominant = 0;
    // Prefer captions where we have them. On p15 the blob detector returned
    // eight hits, all of them sky between laundry on a washing line, while the
    // caption detector returned exactly the nine real captions.
    final captions = <int>[];
    for (var i = 0; i < page.balloons.length; i++) {
      if (page.balloons[i].isCaption) captions.add(i);
    }
    // Captions are the trustworthy source on a real splash, where the blob
    // detector returns noise. On a low-confidence page the blob detector is
    // usually fine and the captions are a minority - using them alone threw
    // away 12 of 18 balloons on issue 100 p13 and showed caption fragments.
    // A page whose layout collapsed ALSO has a dominant panel, so panel size
    // cannot tell a real splash from a detection failure. Confidence can.
    final trueSplash = page.confidence >= 0.5;
    final source = (trueSplash && captions.length >= 3)
        ? captions
        : [for (var i = 0; i < page.balloons.length; i++) i];

    // Do NOT require the text to sit inside the dominant panel: on a splash
    // the narration is spread across the whole page, which is the point.
    final inside = source;
    if (inside.length < 3) return null;

    // Band the captions into rows, then order left-to-right within a row.
    final ordered = List<int>.from(inside)
      ..sort((a, b) {
        final ra = page.balloons[a].rect, rb = page.balloons[b].rect;
        final dy = ra.cy.compareTo(rb.cy);
        return dy != 0 ? dy : ra.cx.compareTo(rb.cx);
      });
    final rows = <List<int>>[];
    for (final i in ordered) {
      final r = page.balloons[i].rect;
      if (rows.isNotEmpty) {
        final last = rows.last
            .map((j) => page.balloons[j].rect)
            .reduce((x, y) => x.union(y));
        if (r.cy <= last.b) {
          rows.last.add(i);
          continue;
        }
      }
      rows.add([i]);
    }
    rows.sort((a, b) {
      final ra = a.map((i) => page.balloons[i].rect).reduce((x, y) => x.union(y));
      final rb = b.map((i) => page.balloons[i].rect).reduce((x, y) => x.union(y));
      return ra.t.compareTo(rb.t);
    });

    final units = <_Unit>[];
    // Establishing shot: the artwork above the first caption row.
    final firstTop =
        rows.first.map((i) => page.balloons[i].rect.t).reduce(math.min);
    if (firstTop > 0.12) {
      units.add(_Unit(dominant, NRect(0, 0, 1, firstTop), const []));
    }
    for (final row in rows) {
      final r = row.map((i) => page.balloons[i].rect).reduce((x, y) => x.union(y));
      units.add(_Unit(dominant,
          NRect(math.max(0, r.l - 0.03), math.max(0, r.t - 0.02),
              math.min(1, r.r + 0.03), math.min(1, r.b + 0.02)),
          row));
    }
    return units;
  }

  /// Fold low-detail, dialogue-free groups into a neighbour.
  List<List<int>> _dropDullArt(
      List<List<int>> groups, List<_Unit> units, PageGuide page) {
    final grid = page.detail;
    if (grid == null || groups.length <= targetMin) return groups;

    final scores = <int, double>{};
    for (var i = 0; i < groups.length; i++) {
      scores[i] = grid.over(_unionOf(units, groups[i].first, groups[i].last + 1));
    }
    final sorted = scores.values.toList()..sort();
    final median = sorted[sorted.length ~/ 2];

    final out = <List<int>>[];
    for (var i = 0; i < groups.length; i++) {
      final hasDialogue =
          groups[i].any((u) => units[u].balloons.isNotEmpty);
      final dull = scores[i]! < median * 0.72;
      if (!hasDialogue && dull && out.isNotEmpty &&
          out.length + (groups.length - i - 1) >= targetMin) {
        out.last.addAll(groups[i]); // fold into the previous beat
      } else {
        out.add(List<int>.from(groups[i]));
      }
    }
    return out;
  }

  bool _allLegible(List<_Unit> units, List<List<int>> part, PageGuide page,
      Size viewport, Size pagePx) {
    for (final g in part) {
      final rect = _unionOf(units, g.first, g.last + 1);
      final focus = [
        for (final i in g) ...units[i].balloons.map((j) => page.balloons[j])
      ];
      if (!_legible(rect, focus, viewport, pagePx)) return false;
    }
    return true;
  }

  NRect _unionOf(List<_Unit> units, int a, int b) =>
      units.sublist(a, b).map((u) => u.rect).reduce((x, y) => x.union(y));

  bool _groupAllowed(List<_Unit> units, int a, int b, Size viewport,
      Size pagePx) {
    if (b - a <= 1) return true; // a lone panel is always a valid beat
    for (var i = a; i < b; i++) {
      if (units[i].keepApart) return false; // split between speakers, keep it
    }
    final rect = _unionOf(units, a, b);
    if (rect.area > maxBeatArea) return false;
    // Without this the DP happily reassembles a sliced column into one
    // full-height group again, undoing the slice we just made. Targeting the
    // shape directly beats tuning a gain threshold: a gain cut-off high enough
    // to block a full-height column also blocked legitimate side-by-side
    // merges at gain 1.93.
    return !_tallAndNarrow(rect);
  }

  double _groupCost(List<_Unit> units, int a, int b, double target,
      PageGuide page, Size viewport, Size pagePx) {
    final rect = _unionOf(units, a, b);
    final dev = rect.area - target;
    var cost = dev * dev;

    // Dead space: a group whose union is much larger than the panels in it is
    // mostly gutter, which is the "pull out that does nothing" beat.
    var covered = 0.0;
    for (var i = a; i < b; i++) {
      covered += units[i].rect.area;
    }
    if (rect.area > 0) {
      final waste = 1 - (covered / rect.area);
      cost += waste * waste * 0.9;
    }

    // Prefer groups whose dialogue stays legible, but as a preference now -
    // never as a reason to slice a panel apart.
    final focus = [
      for (var i = a; i < b; i++)
        ...units[i].balloons.map((j) => page.balloons[j])
    ];
    // Weak tiebreaker only. At 0.05 this outweighed the balance term and
    // chose 3+1 over 2+2 to keep one balloon legible.
    if (!_legible(rect, focus, viewport, pagePx)) cost += 0.006;
    return cost;
  }

  List<List<int>>? _partition(List<_Unit> units, int k, PageGuide page,
      Size viewport, Size pagePx) {
    final n = units.length;
    var total = 0.0;
    for (final u in units) {
      total += u.rect.area;
    }
    final target = total / k;

    final dp = List.generate(
        n + 1, (_) => List<double>.filled(k + 1, double.infinity));
    final cut = List.generate(n + 1, (_) => List<int>.filled(k + 1, -1));
    dp[0][0] = 0;

    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= k; j++) {
        for (var a = j - 1; a < i; a++) {
          if (dp[a][j - 1] == double.infinity) continue;
          if (!_groupAllowed(units, a, i, viewport, pagePx)) continue;
          final c = dp[a][j - 1] +
              _groupCost(units, a, i, target, page, viewport, pagePx);
          if (c < dp[i][j]) {
            dp[i][j] = c;
            cut[i][j] = a;
          }
        }
      }
    }
    if (dp[n][k] == double.infinity) return null;

    final groups = <List<int>>[];
    var i = n, j = k;
    while (j > 0) {
      final a = cut[i][j];
      groups.insert(0, [for (var x = a; x < i; x++) x]);
      i = a;
      j--;
    }
    return groups;
  }

  double _partitionCost(List<_Unit> units, List<List<int>> part,
      PageGuide page, Size viewport, Size pagePx) {
    var total = 0.0;
    for (final u in units) {
      total += u.rect.area;
    }
    final target = total / part.length;
    var cost = 0.0;
    for (final g in part) {
      cost += _groupCost(units, g.first, g.last + 1, target, page, viewport, pagePx);
    }
    return cost / part.length;
  }



  /// Grow toward the viewport aspect, stopping before any rule breaks.
  NRect _expand(PageGuide page, _Unit unit, Size viewport, Size pagePx,
      List<NRect> shown, Set<int> seen) {
    const page01 = NRect(0, 0, 1, 1);
    final targetAspect =
        (viewport.width / viewport.height) * (pagePx.height / pagePx.width);
    final panel = page.panels[unit.panel].rect;

    var rect = unit.rect;
    const step = 0.004;
    for (var iter = 0; iter < 400; iter++) {
      final grow = rect.w / rect.h < targetAspect
          ? NRect(rect.l - step, rect.t, rect.r + step, rect.b)
          : NRect(rect.l, rect.t - step, rect.r, rect.b + step);
      final cand = grow.clampTo(page01);
      if (cand.w == rect.w && cand.h == rect.h) break;
      if (!_permitted(page, cand, unit, panel, shown, seen)) break;
      rect = cand;
    }
    return rect;
  }

  bool _permitted(PageGuide page, NRect cand, _Unit unit, NRect panel,
      List<NRect> shown, Set<int> seen) {
    // Bleed is for context, not for growing the shot. Without this a 42% panel
    // expanded to a 54% beat just to match the viewport aspect.
    if (cand.area > unit.rect.area * 1.35 + 0.02) return false;
    // Stay anchored: bleed must not take over the shot.
    if (cand.area > 0 && panel.overlap(cand) / cand.area < minOwnPanelShare) {
      return false;
    }
    // Don't re-show what has already been read.
    var repeat = 0.0;
    for (final s in shown) {
      repeat += s.overlap(cand);
    }
    if (cand.area > 0 && repeat / cand.area > maxRepeatShare) return false;

    // Foreign balloons: a teaser must read as a teaser.
    for (var i = 0; i < page.balloons.length; i++) {
      if (unit.balloons.contains(i)) continue;
      final cap = seen.contains(i) ? backwardBleed : forwardBleed;
      if (cand.fractionOf(page.balloons[i].rect) > cap) return false;
    }
    return true;
  }
}

class _Unit {
  final int panel;
  final NRect rect;
  final List<int> balloons;

  /// Set when this unit came from splitting a panel between two speakers.
  /// Without it the grouping DP simply merges the halves straight back.
  final bool keepApart;

  const _Unit(this.panel, this.rect, this.balloons, {this.keepApart = false});
}
