import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:comic_reader/beat/planner.dart';
import 'package:comic_reader/model/guide.dart';

void main() {
  late Guide guide;

  setUpAll(() {
    final raw = File('test/fixtures/sd1.guide.json').readAsStringSync();
    guide = Guide.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  });

  test('parses the sidecar the Python exporter writes', () {
    expect(guide.version, Guide.currentVersion);
    expect(guide.sourceId, isNotEmpty);
    expect(guide.pages, isNotEmpty);

    final p13 = guide.page(12); // 0-based: Savage Dragon #1 PDF page 13
    expect(p13, isNotNull, reason: 'the page we validated must be present');
    expect(p13!.panels.length, 8);
    expect(p13.balloons, isNotEmpty);
  });

  test('every balloon references a real panel', () {
    for (final page in guide.pages.values) {
      for (final b in page.balloons) {
        expect(b.panel, inInclusiveRange(0, page.panels.length - 1),
            reason: 'page ${page.index} balloon points outside the panel list');
      }
    }
  });

  test('plans beats for a phone, and every balloon is shown by one', () {
    final page = guide.page(12)!;
    // Pixel 7 logical size, page rendered 2000px wide at the PDF aspect.
    const viewport = Size(412, 915);
    const pagePx = Size(2000, 3017);

    final beats = const BeatPlanner().plan(page, viewport, pagePx);
    expect(beats, isNotEmpty);

    final covered = <int>{};
    for (final b in beats) {
      covered.addAll(b.balloons);
    }
    expect(covered.length, page.balloons.length,
        reason: 'a guided read must not skip dialogue');
  });

  test('a smaller screen never gets fewer beats than a larger one', () {
    // The real invariant behind computing beats at read time: a phone must
    // frame at least as tightly as a tablet, or the lettering stops being
    // readable - which is the failure we set out to beat.
    const pagePx = Size(2000, 3017);
    for (final page in guide.pages.values) {
      final phone =
          const BeatPlanner().plan(page, const Size(412, 915), pagePx).length;
      final tablet =
          const BeatPlanner().plan(page, const Size(1194, 834), pagePx).length;
      if (phone == 0 || tablet == 0) continue;
      expect(phone, greaterThanOrEqualTo(tablet),
          reason: 'page ${page.index + 1}: phone $phone < tablet $tablet');
    }
  });

  /// Splash pages (one image, narration floating over it) build beats from
  /// caption rows rather than panels, so the panel-shaped assertions below do
  /// not apply to them.
  bool isSplash(PageGuide p) =>
      p.panels.any((q) => q.rect.area > 0.5) &&
      p.balloons.where((b) => b.isCaption).length >= 3;

  test('a beat never cuts through dialogue it is responsible for', () {
    // The real invariant behind "whole panels": whatever a beat is there to
    // show, it must show completely. Slicing a panel is only wrong when it
    // slices the content.
    const pagePx = Size(2000, 3017);
    for (final page in guide.pages.values) {
      final beats =
          const BeatPlanner().plan(page, const Size(412, 915), pagePx);
      for (final b in beats) {
        for (final i in b.balloons) {
          expect(b.rect.fractionOf(page.balloons[i].rect), greaterThan(0.9),
              reason: 'page ${page.index + 1}: beat clips its own balloon $i');
        }
      }
    }
  });

  test('beat count lands in the 4-6 target where panels allow', () {
    const pagePx = Size(2000, 3017);
    for (final page in guide.pages.values) {
      if (isSplash(page)) continue;
      final beats =
          const BeatPlanner().plan(page, const Size(412, 915), pagePx);
      if (beats.isEmpty || page.panels.length < 4) continue;
      expect(beats.length, inInclusiveRange(4, 6),
          reason: 'page ${page.index + 1} produced ${beats.length} beats');
    }
  });

  test('beats stay inside the page', () {
    final page = guide.page(12)!;
    final beats = const BeatPlanner()
        .plan(page, const Size(412, 915), const Size(2000, 3017));
    for (final b in beats) {
      expect(b.rect.l, greaterThanOrEqualTo(-1e-9));
      expect(b.rect.t, greaterThanOrEqualTo(-1e-9));
      expect(b.rect.r, lessThanOrEqualTo(1 + 1e-9));
      expect(b.rect.b, lessThanOrEqualTo(1 + 1e-9));
      expect(b.rect.w, greaterThan(0));
      expect(b.rect.h, greaterThan(0));
    }
  });

  test('a splash page reads as establishing shot then caption rows', () {
    const pagePx = Size(2000, 3017);
    final splash = guide.pages.values.where(isSplash).toList();
    expect(splash, isNotEmpty, reason: 'page 15 of the fixture is a splash');
    for (final page in splash) {
      final beats = const BeatPlanner().plan(page, const Size(412, 915), pagePx);
      expect(beats.length, inInclusiveRange(3, 8));
      expect(beats.first.isArt, isTrue,
          reason: 'a splash should open on the artwork');
      final captioned = beats.where((b) => b.balloons.isNotEmpty).length;
      expect(captioned, greaterThanOrEqualTo(3),
          reason: 'the narration must be stepped through, not shown at once');
    }
  });
}
