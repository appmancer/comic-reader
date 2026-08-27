import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../source/open_comic.dart';
import 'reader_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String? _folder;
  List<File> _comics = const [];
  bool _scanning = false;
  String? _error;

  /// TODO(saf): Android needs Storage Access Framework *tree* URIs to walk a
  /// folder — the SAF grant is a URI permission, not a filesystem one, so
  /// Directory().list() on the returned path returns nothing. Picking files
  /// goes through the same grant and works today. Folder browsing needs a
  /// DocumentFile-backed source before this ships.
  Future<void> _pickComics() async {
    final picked = await FilePicker.pickFiles(dialogTitle: 'Choose comics');
    if (picked.isEmpty) return;

    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final found = <File>[];
      for (final f in picked) {
        final path = f.path;
        if (path != null && looksLikeComic(path)) found.add(File(path));
      }
      found.sort((a, b) => p.basename(a.path).toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase()));
      if (mounted) {
        setState(() {
          _comics = found;
          _folder = found.isEmpty ? null : p.dirname(found.first.path);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            onPressed: _scanning ? null : _pickComics,
            icon: const Icon(Icons.folder_open),
            tooltip: 'Choose comics',
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_scanning) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text('Could not read that folder.\n\n$_error',
            textAlign: TextAlign.center),
      ));
    }
    if (_folder == null) {
      return const Center(child: Padding(
        padding: EdgeInsets.all(32),
        child: Text('Choose CBZ or PDF comics to begin.',
            textAlign: TextAlign.center),
      ));
    }
    if (_comics.isEmpty) {
      return Center(child: Text('No comics selected.',
          textAlign: TextAlign.center));
    }
    return ListView.builder(
      itemCount: _comics.length,
      itemBuilder: (context, i) {
        final f = _comics[i];
        return ListTile(
          leading: Icon(p.extension(f.path).toLowerCase() == '.pdf'
              ? Icons.picture_as_pdf
              : Icons.folder_zip),
          title: Text(p.basenameWithoutExtension(f.path)),
          subtitle: Text(p.basename(p.dirname(f.path))),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ReaderPage(file: f),
          )),
        );
      },
    );
  }
}
