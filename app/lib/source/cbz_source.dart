/// CBZ (and plain .zip) comics: an archive of page images.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'comic_source.dart';

class CbzSource implements ComicSource {
  final File file;
  final String _id;
  final List<ArchiveFile> _pages;
  final Archive _archive;

  CbzSource._(this.file, this._id, this._archive, this._pages);

  static Future<CbzSource> open(File file) async {
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final pages = archive.files.where((f) {
      if (!f.isFile) return false;
      final name = p.basename(f.name);
      // Mac archives carry a __MACOSX/._foo shadow copy of every entry.
      if (name.startsWith('._') || f.name.startsWith('__MACOSX/')) return false;
      return imageExtensions.contains(p.extension(name).toLowerCase());
    }).toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));

    final id = cheapIdentity(
      byteLength: bytes.length,
      head: Uint8List.sublistView(bytes, 0, bytes.length < 65536 ? bytes.length : 65536),
      pageCount: pages.length,
    );
    return CbzSource._(file, id, archive, pages);
  }

  @override
  String get id => _id;

  @override
  String get displayName => p.basenameWithoutExtension(file.path);

  @override
  int get pageCount => _pages.length;

  @override
  Future<ui.Image> renderPage(int index, {required int targetWidth}) async {
    if (index < 0 || index >= _pages.length) {
      throw RangeError.index(index, _pages, 'page');
    }
    final content = _pages[index].readBytes();
    if (content == null) {
      throw StateError('page $index could not be read from ${file.path}');
    }
    return decodeScaled(Uint8List.fromList(content), targetWidth);
  }

  @override
  Future<void> dispose() async {
    _archive.clear();
  }
}
