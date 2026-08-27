import 'package:flutter/material.dart';

import 'ui/library_page.dart';

void main() => runApp(const ComicReaderApp());

class ComicReaderApp extends StatelessWidget {
  const ComicReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Comic Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE5007D),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const LibraryPage(),
    );
  }
}
