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

  const Beat({required this.rect, required this.balloons, this.isArt = false});

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
    if (page.panels.isEmpty || page.confidence < 0.5) return const [];

    // Balloons grouped by owning panel, panels already in reading order.
    final byPanel = <int, List<int>>{};
    for (var i = 0; i < page.balloons.length; i++) {
      byPanel.putIfAbsent(page.balloons[i].panel, () => []).add(i);
    }

    // 1. One unit per panel. Never split a panel across beats: slicing one is
    //    what produced close-ups of an eye, a mouth and a shoulder.
    final units = <_Unit>[];
    for (var pi = 0; pi < page.panels.length; pi++) {
      units.add(_Unit(pi, page.panels[pi].rect, byPanel[pi] ?? const <int>[]));
    }

    // 1b. Absorb sliver panels into a neighbour. A 1.5%-of-page strip is
    //     detector noise and should never become a focus point of its own.
    const minUnitArea = 0.03;
    for (var i = units.length - 1; i >= 0 && units.length > 1; i--) {
      if (units[i].rect.area >= minUnitArea) continue;
      final j = (i == 0) ? 1 : i - 1;
      units[j] = _Unit(units[j].panel, units[j].rect.union(units[i].rect),
          [...units[j].balloons, ...units[i].balloons]);
      units.removeAt(i);
    }

    // 2. Group consecutive units into 4-6 beats, balanced by area. A greedy
    //    merge takes as many as fit and strands the remainder, which is how
    //    four equal panels became 3 + 1 instead of 2 + 2.
    var grouped = _bestGrouping(units, page, viewport, pagePx);
    grouped = _mergeAdjacent(grouped, units, page, viewport, pagePx);

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

    // 3. Expand each beat toward the viewport shape, honouring the bleed caps.
    final beats = <Beat>[];
    final shown = <NRect>[];
    final seen = <int>{};
    for (final u in merged) {
      final rect = _expand(page, u, viewport, pagePx, shown, seen);
      beats.add(Beat(
        rect: rect,
        balloons: u.balloons,
        isArt: u.balloons.isEmpty,
      ));
      shown.add(rect);
      seen.addAll(u.balloons);
      for (var i = 0; i < page.balloons.length; i++) {
        if (rect.fractionOf(page.balloons[i].rect) > 0.85) seen.add(i);
      }
    }
    return beats;
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
        final rect = _unionOf(units, a.first, b.last + 1);
        if (rect.area > maxBeatArea) continue;
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

  bool _groupAllowed(List<_Unit> units, int a, int b) {
    if (b - a <= 1) return true; // a lone panel is always a valid beat
    return _unionOf(units, a, b).area <= maxBeatArea;
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
          if (!_groupAllowed(units, a, i)) continue;
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
  const _Unit(this.panel, this.rect, this.balloons);
}
