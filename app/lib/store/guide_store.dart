/// Where guides come from.
///
/// The local store is authoritative and keyed by content identity, so guides
/// survive the user reorganising their library and work for sources we cannot
/// write to (cloud storage, OPDS servers). A sidecar file is an import/export
/// convenience, never a dependency.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../model/guide.dart';

class GuideStore {
  Directory? _dir;

  Future<Directory> _guideDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'guides'));
    if (!await d.exists()) await d.create(recursive: true);
    return _dir = d;
  }

  File _localFile(Directory d, String sourceId) =>
      File(p.join(d.path, '$sourceId.json'));

  /// Local store first; fall back to a sidecar beside the comic and adopt it.
  Future<Guide?> load(String sourceId, {File? beside}) async {
    final dir = await _guideDir();
    final local = _localFile(dir, sourceId);
    if (await local.exists()) {
      final g = Guide.tryParse(await local.readAsString());
      if (g != null) return g;
    }
    if (beside != null) {
      for (final candidate in _sidecarPaths(beside)) {
        final f = File(candidate);
        if (await f.exists()) {
          final g = Guide.tryParse(await f.readAsString());
          if (g != null) {
            await save(sourceId, g); // adopt into the local store
            return g;
          }
        }
      }
    }
    return null;
  }

  Future<void> save(String sourceId, Guide guide) async {
    final dir = await _guideDir();
    await _localFile(dir, sourceId)
        .writeAsString(jsonEncode(guide.toJson()), flush: true);
  }

  /// Export beside the comic, when the location is writable. Best effort.
  Future<bool> exportSidecar(File comic, Guide guide) async {
    try {
      final out = File(_sidecarPaths(comic).first);
      await out.writeAsString(jsonEncode(guide.toJson()), flush: true);
      return true;
    } on FileSystemException {
      return false; // read-only source; the local store still has it
    }
  }

  List<String> _sidecarPaths(File comic) {
    final dir = p.dirname(comic.path);
    final stem = p.basenameWithoutExtension(comic.path);
    return [
      p.join(dir, '$stem.guide.json'),
      p.join(dir, '$stem.json'),
    ];
  }
}
