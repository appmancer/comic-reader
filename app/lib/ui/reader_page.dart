import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../beat/planner.dart';
import '../model/guide.dart';
import '../source/comic_source.dart';
import '../source/open_comic.dart';
import '../store/guide_store.dart';

/// Page render width. Beats crop into this, so it needs headroom over the
/// screen width or a tight beat goes soft.
const _renderWidth = 2000;

class ReaderPage extends StatefulWidget {
  final File file;
  const ReaderPage({super.key, required this.file});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage>
    with SingleTickerProviderStateMixin {
  ComicSource? _source;
  Guide? _guide;
  String? _error;

  int _pageIndex = 0;
  ui.Image? _image;

  /// -1 = whole page before the beats, 0..n-1 = beats, n = whole page after.
  int _step = -1;
  List<Beat> _beats = const [];

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
  );
  NRect _from = const NRect(0, 0, 1, 1);
  NRect _to = const NRect(0, 0, 1, 1);

  final _store = GuideStore();

  /// EXPERIMENTAL detail-density filter, toggled from the app bar so it can be
  /// compared on real pages rather than the one it was tuned against.
  bool _useDetail = false;
  BeatPlanner get _planner => BeatPlanner(useDetail: _useDetail);

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _anim.dispose();
    _image?.dispose();
    _source?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final src = await openComic(widget.file);
      if (src == null) throw StateError('Unsupported file type');
      final guide = await _store.load(src.id, beside: widget.file);
      if (!mounted) return;
      setState(() {
        _source = src;
        _guide = guide;
      });
      await _loadPage(0);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadPage(int index) async {
    final src = _source;
    if (src == null || index < 0 || index >= src.pageCount) return;
    try {
      final img = await src.renderPage(index, targetWidth: _renderWidth);
      if (!mounted) {
        img.dispose();
        return;
      }
      _image?.dispose();
      setState(() {
        _pageIndex = index;
        _image = img;
        _step = -1;
        _beats = const [];
        _from = _to = const NRect(0, 0, 1, 1);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _replan() {
    setState(() {
      _beats = const [];
      _step = -1;
      _from = _to = const NRect(0, 0, 1, 1);
    });
  }

  void _planIfNeeded(Size viewport) {
    if (_beats.isNotEmpty || _image == null) return;
    final page = _guide?.page(_pageIndex);
    if (page == null) return;
    final pagePx = Size(_image!.width.toDouble(), _image!.height.toDouble());
    final beats = _planner.plan(page, viewport, pagePx);
    if (beats.isEmpty) return;
    _beats = beats;
    // Planning happens during layout, so the app bar was already built with the
    // stale value and would read "no guide" until something else triggered a
    // rebuild. Schedule one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _goTo(NRect target) {
    _from = _current;
    _to = target;
    _anim.forward(from: 0);
  }

  NRect get _current {
    if (!_anim.isAnimating) return _to;
    final t = Curves.easeInOutCubic.transform(_anim.value);
    return NRect(
      _from.l + (_to.l - _from.l) * t,
      _from.t + (_to.t - _from.t) * t,
      _from.r + (_to.r - _from.r) * t,
      _from.b + (_to.b - _from.b) * t,
    );
  }

  void _advance(int dir) {
    const whole = NRect(0, 0, 1, 1);
    final last = _beats.length; // index of the trailing whole-page step
    var next = _step + dir;

    if (next < -1) {
      if (_pageIndex > 0) _loadPage(_pageIndex - 1);
      return;
    }
    if (next > last) {
      if (_pageIndex + 1 < (_source?.pageCount ?? 0)) {
        _loadPage(_pageIndex + 1);
      }
      return;
    }
    setState(() => _step = next);
    _goTo(next < 0 || next >= last ? whole : _beats[next].rect);
  }

  @override
  Widget build(BuildContext context) {
    final title = _source?.displayName ?? widget.file.path.split('/').last;
    final total = _source?.pageCount ?? 0;
    final guided = _beats.isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: _useDetail
                ? 'Detail filter ON (experimental)'
                : 'Detail filter off',
            icon: Icon(_useDetail ? Icons.auto_awesome : Icons.auto_awesome_outlined),
            color: _useDetail ? Colors.amberAccent : Colors.white70,
            onPressed: () {
              _useDetail = !_useDetail;
              _replan();
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              total == 0
                  ? ''
                  : 'page ${_pageIndex + 1} / $total'
                      '${guided ? '   ·   ${_stepLabel()}' : '   ·   no guide'}'
                      '${_useDetail ? '   ·   detail' : ''}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  String _stepLabel() {
    if (_step < 0) return 'full page';
    if (_step >= _beats.length) return 'full page';
    return 'beat ${_step + 1} / ${_beats.length}';
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(_error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70)),
      ));
    }
    final img = _image;
    if (img == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(builder: (context, constraints) {
      _planIfNeeded(Size(constraints.maxWidth, constraints.maxHeight));
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _advance(
            d.localPosition.dx > constraints.maxWidth / 2 ? 1 : -1),
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v.abs() > 200) _advance(v < 0 ? 1 : -1);
        },
        child: AnimatedBuilder(
          animation: _anim,
          builder: (_, _) => CustomPaint(
            size: Size.infinite,
            painter: _PagePainter(image: img, view: _current),
          ),
        ),
      );
    });
  }
}

class _PagePainter extends CustomPainter {
  final ui.Image image;
  final NRect view;

  _PagePainter({required this.image, required this.view});

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTRB(
      view.l * image.width,
      view.t * image.height,
      view.r * image.width,
      view.b * image.height,
    );
    if (src.width <= 0 || src.height <= 0) return;

    // Letterbox: fit the region, never crop it. Black bars are a design choice.
    final scale = (size.width / src.width) < (size.height / src.height)
        ? size.width / src.width
        : size.height / src.height;
    final w = src.width * scale;
    final h = src.height * scale;
    final dst = Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h);

    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_PagePainter old) =>
      old.image != image ||
      old.view.l != view.l ||
      old.view.t != view.t ||
      old.view.r != view.r ||
      old.view.b != view.b;
}
