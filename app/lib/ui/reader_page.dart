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

  /// Colour of the page's own border, used to mask out everything a beat is
  /// not about. Sampled from the rendered page so it matches whatever the
  /// printer used - black on most Savage Dragon pages, white on Absalom.
  Color _border = Colors.black;

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
      final border = await _sampleBorder(img);
      _image?.dispose();
      setState(() {
        _pageIndex = index;
        _border = border;
        _image = img;
        _step = -1;
        _beats = const [];
        _from = _to = const NRect(0, 0, 1, 1);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Modal colour of the page's outer edge.
  Future<Color> _sampleBorder(ui.Image img) async {
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return Colors.black;
    final w = img.width, h = img.height;
    final counts = <int, int>{};
    void take(int x, int y) {
      final o = (y * w + x) * 4;
      if (o < 0 || o + 3 >= data.lengthInBytes) return;
      // quantise so near-identical shades group together
      final r = data.getUint8(o) & 0xF0;
      final g = data.getUint8(o + 1) & 0xF0;
      final b = data.getUint8(o + 2) & 0xF0;
      final key = (r << 16) | (g << 8) | b;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    for (var x = 0; x < w; x += 4) {
      take(x, 1);
      take(x, h - 2);
    }
    for (var y = 0; y < h; y += 4) {
      take(1, y);
      take(w - 2, y);
    }
    if (counts.isEmpty) return Colors.black;
    final best = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    return Color(0xFF000000 | best);
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
    _prevFocus = (_step >= 0 && _step < _beats.length)
        ? _beats[_step].focus
        : const [];
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

  /// Panels to keep visible. During a transition we keep BOTH the beat we are
  /// leaving and the one we are arriving at, so the mask slides with the pan
  /// rather than snapping into existence when it lands.
  List<NRect> _prevFocus = const [];

  List<NRect> get _maskFocus {
    final now = (_step < 0 || _step >= _beats.length)
        ? const <NRect>[]
        : _beats[_step].focus;
    // A whole-page step is unmasked by design.
    if (now.isEmpty) return const [];
    if (_anim.isAnimating && _prevFocus.isNotEmpty) {
      return [..._prevFocus, ...now];
    }
    return now;
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
            painter: _PagePainter(
              image: img,
              view: _current,
              focus: _maskFocus,
              border: _border,
            ),
          ),
        ),
      );
    });
  }
}

class _PagePainter extends CustomPainter {
  final ui.Image image;
  final NRect view;
  final List<NRect> focus;
  final Color border;

  _PagePainter({
    required this.image,
    required this.view,
    this.focus = const [],
    this.border = Colors.black,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Fill first: the letterbox bars were the Scaffold's black while the mask
    // used the page's border colour, so a light-bordered page flicked from
    // black to white as the mask appeared.
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = border);

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

    if (focus.isEmpty) return;
    // Paint out everything the beat is not about, in the page's own border
    // colour, so an adjacent panel cannot compete for attention.
    final keep = Path();
    for (final f in focus) {
      final l = dst.left + (f.l - view.l) / view.w * dst.width;
      final t = dst.top + (f.t - view.t) / view.h * dst.height;
      final r = dst.left + (f.r - view.l) / view.w * dst.width;
      final b = dst.top + (f.b - view.t) / view.h * dst.height;
      keep.addRect(Rect.fromLTRB(l, t, r, b));
    }
    final mask = Path.combine(PathOperation.difference,
        Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)), keep);
    canvas.drawPath(mask, Paint()..color = border);
  }

  @override
  bool shouldRepaint(_PagePainter old) =>
      old.image != image ||
      old.focus.length != focus.length ||
      old.border != border ||
      old.view.l != view.l ||
      old.view.t != view.t ||
      old.view.r != view.r ||
      old.view.b != view.b;
}
