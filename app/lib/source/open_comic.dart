/// Factory: pick the right ComicSource for a file.
library;

import 'dart:io';
import 'package:path/path.dart' as p;

import 'cbz_source.dart';
import 'comic_source.dart';
import 'pdf_source.dart';

const comicExtensions = {'.cbz', '.zip', '.pdf'};

bool looksLikeComic(String path) =>
    comicExtensions.contains(p.extension(path).toLowerCase());

Future<ComicSource?> openComic(File file) async {
  switch (p.extension(file.path).toLowerCase()) {
    case '.cbz':
    case '.zip':
      return CbzSource.open(file);
    case '.pdf':
      return PdfSource.open(file);
    default:
      return null;
  }
}
