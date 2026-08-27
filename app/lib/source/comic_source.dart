/// A comic the reader can page through, regardless of container format.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

abstract class ComicSource {
  /// Stable identity used to key the guide database.
  ///
  /// Deliberately cheap: size + a hash of the first 64KB + page count. Hashing
  /// a whole 50MB CBZ would mean a full download when the file lives on cloud
  /// storage or an OPDS server, and this is plenty for a personal library.
  String get id;

  String get displayName;
  int get pageCount;

  /// Decode page [index], scaled so its width is about [targetWidth] pixels.
  /// Callers must dispose the returned image.
  Future<ui.Image> renderPage(int index, {required int targetWidth});

  Future<void> dispose();
}

/// FNV-1a over the head of the file, mixed with size and page count.
/// Not cryptographic — an identity, not a signature.
String cheapIdentity({
  required int byteLength,
  required Uint8List head,
  required int pageCount,
}) {
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  const mask = 0xFFFFFFFFFFFFFFFF;
  for (final b in head) {
    hash = ((hash ^ b) * prime) & mask;
  }
  for (final v in [byteLength, pageCount]) {
    var x = v;
    for (var i = 0; i < 8; i++) {
      hash = ((hash ^ (x & 0xFF)) * prime) & mask;
      x >>= 8;
    }
  }
  // Dart's int is SIGNED 64-bit: masking does not make it unsigned, and
  // toRadixString would emit a leading '-' whenever the top bit is set. Render
  // as two unsigned 32-bit halves so this matches Python's format(h, '016x').
  final hi = (hash >>> 32) & 0xFFFFFFFF;
  final lo = hash & 0xFFFFFFFF;
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}

Future<Uint8List> readHead(File f, {int bytes = 65536}) async {
  final raf = await f.open();
  try {
    final len = await raf.length();
    return await raf.read(len < bytes ? len : bytes);
  } finally {
    await raf.close();
  }
}

/// Decode encoded image bytes (JPEG/PNG/WebP) at roughly [targetWidth].
Future<ui.Image> decodeScaled(Uint8List bytes, int targetWidth) async {
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
  }
}

/// "page2" must sort before "page10" — plain string order gets this wrong and
/// silently scrambles a comic.
int naturalCompare(String a, String b) {
  final ra = RegExp(r'\d+|\D+');
  final pa = ra.allMatches(a).map((m) => m[0]!).toList();
  final pb = ra.allMatches(b).map((m) => m[0]!).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final x = pa[i], y = pb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = (nx != null && ny != null)
        ? nx.compareTo(ny)
        : x.toLowerCase().compareTo(y.toLowerCase());
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}

const imageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'};
