import 'package:gal_protocol/gal_protocol.dart';
import 'package:test/test.dart';

/// `events/<事件id>/event.json`：**文件夹名就是 id**（不再写 `id` / `name`），
/// 一块 = 一张图 + 若干句；`image: null` 表示沿用上一张。
///
/// 运行时读 [EventDef.frames]：**每块一帧**（块内多句按换行拼成整屏文字），
/// 因为「点一下翻下一块」才是播放的粒度。
void main() {
  test('id 来自文件夹名（命名参数）', () {
    final e = EventDef.fromJson({'slides': []}, id: 'end_csrj');
    expect(e.id, 'end_csrj');
  });

  test('每块一帧：块内多句换行拼起来，图片沿用给下一块', () {
    final e = EventDef.fromJson(
      {
        'slides': [
          {
            'image': 'cover.png',
            'text': ['第一句', '第二句'],
          },
          {
            'image': null,
            'text': ['第三句'],
          },
        ],
      },
      id: 'end_demo',
    );
    expect(e.slides, hasLength(2));
    expect(e.slides.first.text, ['第一句', '第二句']);
    expect(e.frames, hasLength(2), reason: '播放单位是块，不是句');
    expect(e.frames.first.text, '第一句\n第二句');
    expect(e.frames.last.text, '第三句');
    // image:null 已经解析成「沿用上一张」
    expect(e.frames.map((f) => f.image), ['cover.png', 'cover.png']);
  });

  test('第一块的 image 是 null 时整段都没有图（不会崩）', () {
    final e = EventDef.fromJson(
      {
        'slides': [
          {
            'text': ['甲'],
          },
          {
            'image': 'b.png',
            'text': ['乙'],
          },
          {
            'image': null,
            'text': ['丙'],
          },
        ],
      },
      id: 'e',
    );
    expect(e.frames.map((f) => f.image), [null, 'b.png', 'b.png']);
  });

  test('一块只写一句字符串也认（作者手写时的常见写法）', () {
    final e = EventDef.fromJson(
      {
        'slides': [
          {'image': 'cover.png', 'text': '只有一句'},
        ],
      },
      id: 'e',
    );
    expect(e.frames.map((f) => f.text), ['只有一句']);
    expect(e.frames.single.image, 'cover.png');
  });

  test('frames 与 slides 一一对应（游标 slideIndex 就是块号）', () {
    final e = EventDef.fromJson(
      {
        'slides': [
          {'image': 'a.png', 'text': <String>[]},
          {'text': ['有内容']},
        ],
      },
      id: 'e',
    );
    expect(e.frames, hasLength(2), reason: '空块也占一屏（校验器会给 warning 让作者去修）');
    expect(e.frames.first.text, '');
    expect(e.frames.last.image, 'a.png', reason: '上一块的图仍然被继承');
  });

  test('target 与情景同格式：顺序 + 可选 require + 若干等概率目的地', () {
    final e = EventDef.fromJson(
      {
        'slides': [
          {'text': ['结束']},
        ],
        'target': [
          {
            'require': '"戒戒堕落" <= 65',
            'kind': [
              {'kind': 'story', 'to': 'endless_human_day'},
            ],
          },
          {
            'kind': [
              {'kind': 'appShell', 'to': 'home'},
            ],
          },
        ],
      },
      id: 'e',
    );
    expect(e.target, hasLength(2));
    expect(e.target.first.require, '"戒戒堕落" <= 65');
    expect(e.target.first.kinds.single.to, 'endless_human_day');
    expect(e.target.last.isFallback, isTrue);
    expect(e.target.last.kinds.single.kind, 'appShell');
  });

  test('没有 slides / target 也能解析（校验器负责提示）', () {
    final e = EventDef.fromJson(const {}, id: 'e');
    expect(e.slides, isEmpty);
    expect(e.frames, isEmpty);
    expect(e.target, isEmpty);
  });
}
