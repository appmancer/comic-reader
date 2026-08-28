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

  /// Largest share of the page a single beat may cover. Legibility alone does
  /// not bound a beat with no dialogue in it - nothing keeps it from swallowing
  /// half the page - so art panels need a geometric limit as well.
  final double maxBeatArea;

  /// Caps, as fractions of an individual balloon's area.
  final double forwardBleed;
  final double backwardBleed;
  final double minOwnPanelShare;
  final double maxRepeatShare;

  const BeatPlanner({
    this.minLineHeightPx = 13.0,
    this.maxBeatArea = 0.34,
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
      if (b.lineHeight <= 0) continue; // analyser didn't measure it
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

    // 1. One unit per panel; split a panel too tall to stay legible.
    final units = <_Unit>[];
    for (var pi = 0; pi < page.panels.length; pi++) {
      final panel = page.panels[pi].rect;
      final ids = byPanel[pi] ?? const <int>[];
      final focus = ids.map((i) => page.balloons[i]).toList();

      var slices = 1;
      while (slices < 6 &&
          (_slice(panel, slices, 0).area > maxBeatArea ||
              !_legible(_slice(panel, slices, 0), focus, viewport, pagePx))) {
        slices++;
      }
      if (slices == 1) {
        units.add(_Unit(pi, panel, ids));
      } else {
        for (var s = 0; s < slices; s++) {
          final r = _slice(panel, slices, s);
          final inSlice = ids
              .where((i) => _centreIn(page.balloons[i].rect, r))
              .toList();
          units.add(_Unit(pi, r, inSlice));
        }
      }
    }

    // 2. Merge consecutive units while the union stays legible and in one panel row.
    final merged = <_Unit>[];
    for (final u in units) {
      if (merged.isEmpty) {
        merged.add(u);
        continue;
      }
      final last = merged.last;
      final union = last.rect.union(u.rect);
      final focus = [...last.balloons, ...u.balloons]
          .map((i) => page.balloons[i])
          .toList();
      if (union.area <= maxBeatArea && _legible(union, focus, viewport, pagePx)) {
        merged[merged.length - 1] =
            _Unit(last.panel, union, [...last.balloons, ...u.balloons]);
      } else {
        merged.add(u);
      }
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

  NRect _slice(NRect panel, int n, int i) => NRect(
        panel.l,
        panel.t + panel.h * i / n,
        panel.r,
        panel.t + panel.h * (i + 1) / n,
      );

  bool _centreIn(NRect r, NRect box) =>
      r.cx >= box.l && r.cx <= box.r && r.cy >= box.t && r.cy <= box.b;

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
