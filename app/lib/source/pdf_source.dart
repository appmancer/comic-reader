/// PDF comics, rendered page-to-bitmap via PDFium (pdfrx).
///
/// This is the reason the app is Flutter: 77% of the reference library is PDF,
/// and page->bitmap at an arbitrary scale is off the shelf here.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'comic_source.dart';

class PdfSource implements ComicSource {
  final File file;
  final String _id;
  final PdfDocument _doc;

  PdfSource._(this.file, this._id, this._doc);

  static Future<PdfSource> open(File file) async {
    final doc = await PdfDocument.openFile(file.path);
    final id = cheapIdentity(
      byteLength: await file.length(),
      head: await readHead(file),
      pageCount: doc.pages.length,
    );
    return PdfSource._(file, id, doc);
  }

  @override
  String get id => _id;

  @override
  String get displayName => p.basenameWithoutExtension(file.path);

  @override
  int get pageCount => _doc.pages.length;

  @override
  Future<ui.Image> renderPage(int index, {required int targetWidth}) async {
    final page = _doc.pages[index];
    final scale = targetWidth / page.width;
    // fullWidth/fullHeight are the virtual page size; width/height would be a
    // SUB-AREA of it. Omitting the latter renders the whole page scaled.
    //
    // TODO(perf): a beat only needs its own region. Passing x/y/width/height
    // here would let us render the crop at full resolution instead of
    // rendering the entire page large and cropping in the painter.
    final rendered = await page.render(
      fullWidth: targetWidth.toDouble(),
      fullHeight: page.height * scale,
      backgroundColor: 0xFFFFFFFF,
    );
    if (rendered == null) {
      throw StateError('page $index failed to render in ${file.path}');
    }
    try {
      return await rendered.createImage();
    } finally {
      rendered.dispose();
    }
  }

  @override
  Future<void> dispose() async => _doc.dispose();
}
