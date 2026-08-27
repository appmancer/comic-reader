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

  test('a tablet gets a different plan from a phone', () {
    final page = guide.page(12)!;
    const pagePx = Size(2000, 3017);
    final phone = const BeatPlanner()
        .plan(page, const Size(412, 915), pagePx)
        .map((b) => b.rect.toString())
        .toList();
    final tablet = const BeatPlanner()
        .plan(page, const Size(1600, 2560), pagePx)
        .map((b) => b.rect.toString())
        .toList();

    expect(phone, isNotEmpty);
    expect(tablet, isNotEmpty);
    // The whole point of computing at read time rather than baking beats in.
    expect(phone, isNot(equals(tablet)));
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
}
