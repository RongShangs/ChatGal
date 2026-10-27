import 'error_code.dart';
import 'models/manifest.dart';
import 'scene_v2.dart';
import 'validation_error.dart';

/// `key` 写了、但类型不对时**当场报错**，别当成「没写」。
///
/// `"choice": [ … ]`（照着 `target` 的数组写法抄）、写成字符串、键名打错，
/// 都是一眼看着像对的写法；静默忽略会让作者的出口凭空消失 ——
/// 二选一的检查也不会触发，只剩一条「事件没有出口」的 warning。
void _requireType(
  String id,
  String key,
  Object? value,
  bool Function(Object? v) ok,
  String expect,
) {
  // 没写 / 写 null = 合法的「不用这个字段」。
  if (value == null) return;
  if (ok(value)) return;
  throw PackageFormatException([
    ValidationError(
      code: ErrorCodes.invalidType,
      message: 'events/$id/event.json 的 `$key` 必须是$expect',
      path: '/events/$id/$key',
      hint: 'value=$value',
    ),
  ]);
}

/// 事件定义（`events/<事件id>/event.json`）。
///
/// **没有 `id` / `name`**：文件夹名就是 id，也是世界控制台里显示的名字。
/// **没有 `onFinish` / `effects`**：播完之后走的就是每个情景那套 [TargetBlock]
/// 出口判定，写法完全一致。
///
/// 出口有**两种，二选一**：
/// * [target]：与情景相同的出口块（按 `require` 判定 + 块内等概率随机）；
/// * [choice]：**选择题**（事件专有）—— 播完最后一屏后由玩家在选项里点一个，
///   选项直接写目的地，不判数值、不随机。
///
/// 播放单位是**块**（一屏）：点一下进下一块，块内的多句在**同一屏里换行显示**
/// （`text` 数组按换行拼起来）。所以「一块 = 一张图 + 一屏文字」。
class EventDef {
  EventDef({
    required this.id,
    required this.slides,
    this.target = const [],
    this.choice,
  }) : frames = _framesOf(slides);

  final String id;
  final List<EventSlide> slides;

  /// 播放序列：**每块一帧**（`text` 是块内各句按换行拼好的整屏文字，
  /// `image` 为 null 时已解析成「沿用上一张图」）。`slideIndex` 就是它的下标。
  final List<EventFrame> frames;

  final List<TargetBlock> target;

  /// 选择题出口（与 [target] 二选一；校验器会拦「两个都写」）。
  final EventChoice? choice;

  bool get hasChoice => choice != null && choice!.options.isNotEmpty;

  static List<EventFrame> _framesOf(List<EventSlide> slides) {
    final out = <EventFrame>[];
    String? inherited;
    for (final s in slides) {
      if (s.image != null && s.image!.isNotEmpty) inherited = s.image;
      out.add(EventFrame(image: inherited, text: s.text.join('\n')));
    }
    return out;
  }

  factory EventDef.fromJson(Map<String, Object?> json, {required String id}) {
    _requireType(id, 'slides', json['slides'], (v) => v is List, '数组');
    _requireType(id, 'target', json['target'], (v) => v is List, '数组（出口块）');
    _requireType(
      id,
      'choice',
      json['choice'],
      (v) => v is Map,
      '对象（选择题：title + options）',
    );
    final rawChoice = json['choice'];
    return EventDef(
      id: id,
      slides: (json['slides'] as List? ?? const [])
          .map((e) => EventSlide.fromJson(Map<String, Object?>.from(e as Map)))
          .toList(),
      target: (json['target'] as List? ?? const [])
          .map((e) => TargetBlock.fromJson(Map<String, Object?>.from(e as Map)))
          .toList(),
      choice: rawChoice is Map
          ? EventChoice.fromJson(Map<String, Object?>.from(rawChoice))
          : null,
    );
  }

  /// 有选择题就只写 `choice`、没有才写 `target` —— 判据是 [hasChoice]（选项要到手
  /// 才算数）：判 `choice != null` 会把「choice 为空 + target 有效」的事件写成一个
  /// 没有出口的事件。
  Map<String, Object?> toJson() => {
        'slides': slides.map((s) => s.toJson()).toList(),
        if (hasChoice) 'choice': choice!.toJson(),
        if (!hasChoice) 'target': target.map((t) => t.toJson()).toList(),
      };
}

/// 选择题出口：一个问题标题 + 最多 5 个选项。
///
/// 每个选项就是「按钮上的字 + 去哪」，**不判数值、不随机**（与 target 的区别
/// 正在这里：出口由玩家自己决定，所以选项里不用管任何条件与权重）。
class EventChoice {
  const EventChoice({this.title = '', this.options = const []});

  /// 选项上方的标题（可留空）。
  final String title;
  final List<EventChoiceOption> options;

  /// 最多几个选项（校验器与创作台都用它）。
  static const int maxOptions = 5;

  factory EventChoice.fromJson(Map<String, Object?> json) {
    return EventChoice(
      title: (json['title'] as String?) ?? '',
      options: (json['options'] as List? ?? const [])
          .map(
            (e) => EventChoiceOption.fromJson(
              Map<String, Object?>.from(e as Map),
            ),
          )
          .toList(),
    );
  }

  Map<String, Object?> toJson() => {
        if (title.trim().isNotEmpty) 'title': title,
        'options': options.map((o) => o.toJson()).toList(),
      };
}

/// 选择题里的一个选项：`{ "text": "回到主页", "kind": "appShell", "to": "home" }`。
class EventChoiceOption {
  const EventChoiceOption({required this.text, required this.target});

  /// 按钮上显示的字（也是玩家看到的那句话）。
  final String text;

  /// 点它之后去哪（kind = story / event / appShell）。
  final ExitTarget target;

  factory EventChoiceOption.fromJson(Map<String, Object?> json) {
    return EventChoiceOption(
      text: '${json['text'] ?? ''}'.trim(),
      target: ExitTarget.fromJson(json),
    );
  }

  Map<String, Object?> toJson() => {
        'text': text,
        ...target.toJson(),
      };
}

/// 一个画面块：一张图 + 若干句。图片写相对本事件目录的文件名；
/// `null` 表示沿用上一张（多句共用一张背景）。
class EventSlide {
  const EventSlide({this.image, this.text = const []});

  final String? image;
  final List<String> text;

  factory EventSlide.fromJson(Map<String, Object?> json) {
    final raw = json['text'];
    final lines = <String>[];
    if (raw is List) {
      lines.addAll(raw.map((e) => '$e'));
    } else if (raw is String && raw.isNotEmpty) {
      // 容忍「一块只有一句」时直接写字符串。
      lines.add(raw);
    }
    return EventSlide(
      image: (json['image'] as String?)?.trim().isEmpty ?? true
          ? null
          : json['image'] as String?,
      text: lines,
    );
  }

  Map<String, Object?> toJson() => {'image': image, 'text': text};
}

/// 播放序列的一格 = **一块（一屏）**：解析过继承关系的图片名 + 整屏文字。
class EventFrame {
  const EventFrame({this.image, required this.text});

  final String? image;
  final String text;
}
