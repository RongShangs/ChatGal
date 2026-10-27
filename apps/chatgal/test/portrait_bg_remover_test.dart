import 'dart:typed_data';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:chatgal/features/session/portrait_bg_remover.dart';
import 'package:flutter_test/flutter_test.dart';

/// 纯像素抠图：四角采样背景色，相近像素置透明。
void main() {
  test('清缓存后旧解码失效，旧完成回调不删除新请求', () async {
    final gates = <Completer<ui.Image?>>[];
    final remover = PortraitBgRemover(
      imageLoader: (_) {
        final gate = Completer<ui.Image?>();
        gates.add(gate);
        return gate.future;
      },
    );
    final old = remover.process('a');
    remover.clearCache();
    final current = remover.process('a');
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final picture = recorder.endRecording();
    final oldImage = picture.toImageSync(1, 1);
    final newImage = picture.toImageSync(1, 1);
    picture.dispose();
    gates[0].complete(oldImage);
    expect(await old, isNull);
    expect(oldImage.debugDisposed, isTrue);
    expect(identical(remover.process('a'), current), isTrue);
    gates[1].complete(newImage);
    expect(await current, same(newImage));
    expect(await remover.process('a'), same(newImage));
    expect(gates, hasLength(2));
    remover.clearCache();
    expect(newImage.debugDisposed, isTrue);
  });

  group('removeBgRaw', () {
    /// 造一张 w×h 的 RGBA 图：背景色 bg，中心矩形为 fg。
    Uint8List makeImage(int w, int h, List<int> bg, List<int> fg) {
      final p = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          final inFg =
              x >= w ~/ 4 && x < w * 3 ~/ 4 && y >= h ~/ 4 && y < h * 3 ~/ 4;
          final c = inFg ? fg : bg;
          p[i] = c[0];
          p[i + 1] = c[1];
          p[i + 2] = c[2];
          p[i + 3] = 255;
        }
      }
      return p;
    }

    test('白底被抠掉，前景保留', () {
      // 8x8：四角白底 (255,255,255)，中心红块 (200,30,30)
      final pixels = makeImage(8, 8, [255, 255, 255], [200, 30, 30]);
      removeBgRaw(pixels, 8, 8, tolerance: 28);
      // 角落 alpha = 0
      expect(pixels[3], 0, reason: '左上角应被抠掉');
      // 中心 alpha = 255
      final ci = (4 * 8 + 4) * 4;
      expect(pixels[ci + 3], 255, reason: '中心前景应保留');
      expect(pixels[ci], 200);
      expect(pixels[ci + 1], 30);
    });

    test('绿幕被抠掉', () {
      final pixels = makeImage(8, 8, [0, 200, 0], [240, 200, 180]);
      removeBgRaw(pixels, 8, 8, tolerance: 40);
      expect(pixels[3], 0);
      final ci = (4 * 8 + 4) * 4;
      expect(pixels[ci + 3], 255);
    });

    test('前景与背景颜色接近时可能被误抠（已知限制）', () {
      // 容差 80 时浅灰底上的深灰前景可能部分被抠掉 —— 这是预期行为。
      final pixels = makeImage(8, 8, [200, 200, 200], [160, 160, 160]);
      removeBgRaw(pixels, 8, 8, tolerance: 80);
      // 至少角落被抠了
      expect(pixels[3], 0);
    });

    test('全图同色：整张透明', () {
      final p = Uint8List(4 * 4 * 4);
      for (var i = 0; i < p.length; i += 4) {
        p[i] = 255;
        p[i + 1] = 255;
        p[i + 2] = 255;
        p[i + 3] = 255;
      }
      removeBgRaw(p, 4, 4);
      for (var i = 3; i < p.length; i += 4) {
        expect(p[i], 0);
      }
    });

    test('0 尺寸不崩', () {
      removeBgRaw(Uint8List(0), 0, 0);
    });
  });
}
