/// Everything the settlement model is allowed to see.
///
/// Deliberately **not** the raw scene transcript: leaving a scene must not
/// re-inject the whole scene text, and the numbers should follow from the
/// short-term layers the character actually remembered.
class SettlementEvidence {
  const SettlementEvidence({
    required this.owner,
    required this.sceneId,
    required this.sceneName,
    required this.day,
    required this.shortTerm,
    required this.state,
    required this.audience,
  });

  static const empty = SettlementEvidence(
    owner: '',
    sceneId: '',
    sceneName: '',
    day: 0,
    shortTerm: [],
    state: {},
    audience: [],
  );

  final String owner;
  final String sceneId;
  final String sceneName;
  final int day;

  /// L1/L2 texts for this scene visit, already audience-filtered for [owner].
  final List<String> shortTerm;

  /// Current values of the rule's variables (variable id → value).
  final Map<String, Object?> state;

  /// Characters present in this scene.
  final List<String> audience;

  bool get hasContent => shortTerm.isNotEmpty;

  String render() {
    final buf = StringBuffer()
      ..writeln('本幕：$sceneName（第 $day 天）')
      ..writeln('结算对象：$owner')
      ..writeln('在场：${audience.join('、')}');
    if (state.isNotEmpty) {
      buf.writeln('当前数值：$state');
    }
    buf.writeln('<本场景近期记忆>');
    if (shortTerm.isEmpty) {
      buf.writeln('（本场景还没有可用的短期记忆）');
    } else {
      for (final t in shortTerm) {
        buf.writeln('- $t');
      }
    }
    buf.writeln('</本场景近期记忆>');
    return buf.toString();
  }
}
