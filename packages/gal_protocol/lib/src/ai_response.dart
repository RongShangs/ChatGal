/// Normalized AI turn response. Multi-segment for expression changes.
class DialogueSegment {
  const DialogueSegment({
    required this.id,
    required this.speakerId,
    required this.expressionId,
    required this.text,
    this.portraitId,
  });

  final String id;
  final String speakerId;
  final String expressionId;
  final String text;

  /// 模型选中的立绘名（从本轮提交的「本幕可用立绘」表里逐字选）。
  /// 为空时退回 expressionId（表情词）再解析。
  final String? portraitId;

  Map<String, Object?> toJson() => {
        'id': id,
        'speakerId': speakerId,
        'expressionId': expressionId,
        'text': text,
        if (portraitId != null) 'portraitId': portraitId,
      };

  factory DialogueSegment.fromJson(Map<String, Object?> json) {
    final portrait = json['portraitId'] ?? json['portrait'];
    // id / speakerId / text 一律容错：立绘修复请求明确要求模型「不要重复台词」，
    // 那种回包里就没有 text；以前 `json['text']!` 会直接抛异常，整份响应被判
    // 解析失败 —— 于是一个「只补表情选择」的请求永远救不回来。
    // 缺这些字段只丢掉对应的那点信息，不该丢掉整段可用的立绘选择。
    final text = json['text'];
    return DialogueSegment(
      id: '${json['id'] ?? 's1'}',
      speakerId: '${json['speakerId'] ?? 'jj'}',
      // 缺字段就留空，**不要**编一个 'default'：那个词永远不在包的词表里，
      // 会让「模型没给」和「模型给错了」在下游看起来一样（都直接触发兜底）。
      // 留空之后调用方才能区分「没给」与「给了但不合法」。
      expressionId: '${json['expressionId'] ?? ''}',
      text: text is String ? text : '',
      portraitId: portrait is String && portrait.isNotEmpty ? portrait : null,
    );
  }
}

class AIResponse {
  const AIResponse({
    required this.protocolVersion,
    required this.segments,
    this.suggestedReplies = const [],
  });

  final int protocolVersion;
  final List<DialogueSegment> segments;
  final List<String> suggestedReplies;

  Map<String, Object?> toJson() => {
        'protocolVersion': protocolVersion,
        'segments': segments.map((s) => s.toJson()).toList(),
        'suggestedReplies': suggestedReplies,
      };

  factory AIResponse.fromJson(Map<String, Object?> json) {
    final segmentsRaw = json['segments'] as List? ?? const [];
    return AIResponse(
      protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 1,
      segments: segmentsRaw
          .map((e) => DialogueSegment.fromJson(Map<String, Object?>.from(e as Map)))
          .toList(),
      suggestedReplies:
          (json['suggestedReplies'] as List? ?? const []).cast<String>(),
    );
  }
}
