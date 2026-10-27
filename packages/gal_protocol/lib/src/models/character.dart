import '../validation_error.dart';
import 'manifest.dart';

/// 角色定义（`characters/<id>/character.json`）。
///
/// 目录名就是角色 id，也就是游戏内显示的角色名 —— 不再有单独的 `name`。
/// 基础提示词**内联**在 `prompt` 里（不再有 `promptFile` 指向角色目录下的
/// md 文件：一份人格就该在一个地方）。
///
/// `portraits` 映射表已删除：立绘只靠文件名约定
/// `characters/<id>/<状态>_<情绪>.png` 解析（[portraitPathFor]），
/// `states` / `emotions` 是作者显式声明的词表，所以拼名字是精确的，
/// 不需要靠切分「状态_情绪」猜。
class CharacterDef {
  const CharacterDef({
    required this.id,
    required this.prompt,
    this.states = const [],
    this.emotions = const [],
    this.defaultState = '',
    this.defaultEmotion = '',
  });

  final String id;
  final String prompt;

  final List<String> states;
  final List<String> emotions;
  final String defaultState;
  final String defaultEmotion;

  /// 立绘在包内的相对路径（按命名约定拼，不查映射表）。
  String portraitPathFor(String state, String emotion) =>
      'characters/$id/${state}_$emotion.png';

  /// 立绘的键（`状态_情绪`），与文件名 stem 一致。
  static String portraitKey(String state, String emotion) =>
      '${state}_$emotion';

  factory CharacterDef.fromJson(Map<String, Object?> json, {String path = ''}) {
    String reqStr(String key) {
      final v = json[key];
      if (v is! String || v.isEmpty) {
        throw PackageFormatException([
          ProtocolErrors.type(path, key, 'non-empty string', v),
        ]);
      }
      return v;
    }

    List<String> strList(String key) {
      final v = json[key];
      if (v is! List) return const [];
      return v.map((e) => e.toString()).toList();
    }

    final states = strList('states');
    final emotions = strList('emotions');
    return CharacterDef(
      id: reqStr('id'),
      prompt: reqStr('prompt'),
      states: states,
      emotions: emotions,
      defaultState:
          '${json['defaultState'] ?? (states.isNotEmpty ? states.first : '')}',
      // 包没声明默认表情时取它自己声明的第一个情绪 —— 不能猜一个固定词，
      // 情绪词是包自己的词汇表（本默认包是中文）。
      defaultEmotion:
          '${json['defaultEmotion'] ?? (emotions.isNotEmpty ? emotions.first : '')}',
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'prompt': prompt,
        'defaultState': defaultState,
        'defaultEmotion': defaultEmotion,
        'states': states,
        'emotions': emotions,
      };
}
