import 'cancel_token.dart';
import 'dialogue_provider.dart';
import 'parse_ai_response.dart';
import 'provider_result.dart';

/// Offline mock provider for tests and previews.
class MockDialogueProvider implements DialogueProvider {
  MockDialogueProvider({
    this.script,
    this.delay = Duration.zero,
  });

  /// Optional canned raw texts, popped per call.
  final List<String>? script;
  final Duration delay;

  int calls = 0;

  @override
  Future<ProviderResult> generate(
    GenerateRequest request, {
    CancelToken? cancel,
    void Function(String delta)? onDelta,
  }) async {
    calls++;
    if (cancel != null && cancel.isCancelled) {
      return const ProviderResult.failed(
        status: ProviderStatus.cancelled,
        error: 'cancelled',
      );
    }

    final raw = (script != null && script!.isNotEmpty)
        ? script!.removeAt(0)
        : _defaultScript(request);

    // 流式演示：按字吐增量，供 UI 验证打字机/开关。
    if (request.stream && onDelta != null && delay > Duration.zero) {
      for (var i = 0; i < raw.length; i++) {
        if (cancel != null && cancel.isCancelled) {
          return const ProviderResult.failed(
            status: ProviderStatus.cancelled,
            error: 'cancelled',
          );
        }
        onDelta(raw[i]);
        await Future<void>.delayed(delay);
      }
    } else if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    } else if (request.stream && onDelta != null) {
      onDelta(raw);
    }
    if (cancel != null && cancel.isCancelled) {
      return const ProviderResult.failed(
        status: ProviderStatus.cancelled,
        error: 'cancelled',
      );
    }

    final outcome = parseAiResponse(raw);
    if (!outcome.ok) {
      return ProviderResult.failed(
        status: ProviderStatus.formatError,
        error: outcome.error,
        rawText: raw,
      );
    }
    final resp = outcome.response!;
    if (outcome.kind == ParseKind.parsed &&
        resp.segments.isNotEmpty &&
        resp.segments.every((s) => s.text.trim().isEmpty)) {
      return ProviderResult.failed(
        status: ProviderStatus.formatError,
        error: 'empty dialogue text',
        rawText: raw,
      );
    }
    return ProviderResult.ok(response: resp, rawText: raw);
  }

  /// 默认脚本：若本请求带【可用立绘】（通常是**立绘 agent** 的
  /// `buildLookPlanPrompt`），从中挑两张；聊天请求已不再带词表，
  /// 会落到「无词表 → 单段纯台词」分支（§32：聊天只写台词）。
  String _defaultScript(GenerateRequest request) {
    final names = _portraitNames(request.messages);
    if (names.isEmpty) {
      return '''
{
  "protocolVersion": 1,
  "segments": [
    {"id": "s1", "speakerId": "main", "expressionId": "", "text": "（小声）……嗯。"}
  ],
  "suggestedReplies": ["(握住她的手)", "别怕，我在"]
}
''';
    }
    final a = names[calls % names.length];
    final b = names[(calls + 1) % names.length];
    return '''
{
  "protocolVersion": 1,
  "segments": [
    {"id": "s1", "speakerId": "main", "expressionId": "${_emotion(a)}", "portraitId": "$a", "text": "（小声）……嗯。"},
    {"id": "s2", "speakerId": "main", "expressionId": "${_emotion(b)}", "portraitId": "$b", "text": "（抬眼看了看你）"}
  ],
  "suggestedReplies": ["(握住她的手)", "别怕，我在"]
}
''';
  }

  static String _emotion(String portraitName) {
    final i = portraitName.lastIndexOf('_');
    return i >= 0 ? portraitName.substring(i + 1) : portraitName;
  }

  /// 从上下文里的【可用立绘】块取出立绘名列表。
  static List<String> _portraitNames(List<Map<String, String>> messages) {
    for (final m in messages.reversed) {
      final content = m['content'] ?? '';
      final idx = content.indexOf('【可用立绘】');
      if (idx < 0) continue;
      final rest = content.substring(idx + '【可用立绘】'.length);
      final line = rest
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty, orElse: () => '');
      final names = line
          .split('、')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (names.isNotEmpty) return names;
    }
    return const [];
  }
}
