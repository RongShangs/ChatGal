import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 自动抠图：把立绘的**纯色背景**替换为透明。
///
/// 四角采样取背景色，把与背景色距离小于阈值的像素置透明。
/// 适合 Gal 立绘常见的纯色底（白底、绿幕等）；复杂背景无效。
/// 结果按源文件路径缓存（最多 [maxCache] 张）；同一路径的并发请求会合并。
class PortraitBgRemover {
  PortraitBgRemover({this.tolerance = 28, this.maxCache = 24, this.imageLoader})
    : assert(maxCache > 0);

  /// 测试可控制解码完成时机；返回的图像由本缓存持有和释放。
  final Future<ui.Image?> Function(String)? imageLoader;
  int _generation = 0;

  /// 颜色距离阈值（RGB 欧氏距离近似）：越大越容易被抠掉。
  final int tolerance;

  final int maxCache;
  final _cache = <String, ui.Image>{};

  /// 进行中的请求：同一路径并发时共享同一个 Future，不重复处理。
  final _pending = <String, Future<ui.Image?>>{};

  Future<ui.Image?> process(String path) {
    final cached = _cache[path];
    if (cached != null) return Future.value(cached);
    final inflight = _pending[path];
    if (inflight != null) return inflight;
    late final Future<ui.Image?> future;
    future = _doProcess(path, _generation).whenComplete(() {
      if (identical(_pending[path], future)) _pending.remove(path);
    });
    _pending[path] = future;
    return future;
  }

  Future<ui.Image?> _doProcess(String path, int generation) async {
    try {
      final image = imageLoader != null
          ? await imageLoader!(path)
          : await _keyOut(await File(path).readAsBytes());
      if (image == null) return null;
      if (generation != _generation) {
        image.dispose();
        return null;
      }
      if (_cache.length >= maxCache) {
        // 淘汰最早的：先 dispose 再移除，避免 Image 句柄泄漏。
        final oldest = _cache.keys.first;
        _cache.remove(oldest)?.dispose();
      }
      _cache[path] = image;
      return image;
    } catch (_) {
      return null;
    }
  }

  Future<ui.Image?> _keyOut(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    ui.Image? src;
    try {
      final frame = await codec.getNextFrame();
      src = frame.image;
      final w = src.width;
      final h = src.height;
      if (w == 0 || h == 0) {
        return null;
      }
      final data = await src.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      final pixels = data.buffer.asUint8List();
      removeBgRaw(pixels, w, h, tolerance: tolerance);
      return await _imageFromRgba(pixels, w, h);
    } finally {
      src?.dispose();
      codec.dispose();
    }
  }

  Future<ui.Image> _imageFromRgba(Uint8List pixels, int w, int h) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: w,
        height: h,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      // frame.image 持有自己的引用，codec/buffer 可以释放。
      return frame.image;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  void clearCache() {
    _generation++;
    for (final img in _cache.values) {
      img.dispose();
    }
    _cache.clear();
    _pending.clear();
  }
}

/// 全局单例。设置开关切换时调用 [PortraitBgRemover.clearCache]。
final portraitBgRemover = PortraitBgRemover();

/// 纯像素抠图（RGBA 字节数组进、出；可单测，不依赖 Flutter binding）。
void removeBgRaw(
  Uint8List pixels,
  int width,
  int height, {
  int tolerance = 28,
}) {
  if (width <= 0 || height <= 0) return;
  final corners = <List<int>>[
    _px(pixels, width, 0, 0),
    _px(pixels, width, width - 1, 0),
    _px(pixels, width, 0, height - 1),
    _px(pixels, width, width - 1, height - 1),
  ];
  var br = 0, bg = 0, bb = 0;
  for (final c in corners) {
    br += c[0];
    bg += c[1];
    bb += c[2];
  }
  br = (br / 4).round();
  bg = (bg / 4).round();
  bb = (bb / 4).round();
  final tolSq = tolerance * tolerance;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      final dr = pixels[i] - br;
      final dg = pixels[i + 1] - bg;
      final db = pixels[i + 2] - bb;
      if (dr * dr + dg * dg + db * db <= tolSq) {
        pixels[i + 3] = 0;
      }
    }
  }
}

List<int> _px(Uint8List p, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return [p[i], p[i + 1], p[i + 2]];
}
