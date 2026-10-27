import 'dart:async';

import 'package:gal_protocol/gal_protocol.dart';

import 'cancel_token.dart';
import 'dialogue_provider.dart';
import 'provider_result.dart';

/// 一个会话串行执行的回合协调器：AI 只**提案**，限幅与落库由调用方完成，
/// 迟到的响应绝不提交。
///
/// 闸门**只有 CancelToken 一道**：`_busy` 对同一 session 是排他的（并发提交直接
/// 被拒），所以回合在飞期间不可能有另一个回合改掉这里的状态；以前那条 revision
/// 守卫在 `_busy` 下永远不可达，已删。切换存档/场景时由调用方 `cancel()`。
///
/// v2 里引擎动作（`playerAction` / `adjustStat` 等）已全部删除：回合内唯一
/// 数值不由这里改：只有离场结算与入场改值会动世界状态。
/// 剧情的推进（换场、结算、出口）不在这里，见 `TransitionCoordinator`。
class TurnCoordinator {
  TurnCoordinator({
    required this.provider,
  });

  final DialogueProvider provider;
  final Map<String, int> _revision = {};
  final Set<String> _busy = {};
  final Map<String, CancelToken> _active = {};

  int revisionOf(String sessionId) => _revision[sessionId] ?? 0;

  bool isBusy(String sessionId) => _busy.contains(sessionId);

  /// Cancel in-flight turn for session (switching save etc.).
  void cancel(String sessionId) {
    _active[sessionId]?.cancel();
  }

  /// 提交一个回合。
  ///
  /// [assembledMessages] 是调用方按 L1 活跃窗口 + audience + 各层预算组装好的
  /// 上下文；给了就用它，不再从 [messages] 全量重建。
  /// [ranges] 来自包的变量注册表（保留参数，供未来需要时使用）。
  Future<TurnOutcome> submit({
    required String sessionId,
    required WorldSnapshot world,
    required List<Map<String, Object?>> messages,
    required String userText,
    List<Map<String, String>>? assembledMessages,
    List<String> audience = const [],
    bool opening = false,
    Map<String, ({num? min, num? max})> ranges = const {},
    bool stream = false,
    void Function(String delta)? onDelta,
  }) async {
    if (_busy.contains(sessionId)) {
      return TurnOutcome.rejected(
        'session busy',
        world: world,
        messages: messages,
      );
    }
    final startRev = revisionOf(sessionId);
    final token = CancelToken();
    _busy.add(sessionId);
    _active[sessionId] = token;

    try {
      final List<Map<String, String>> requestMessages;
      if (assembledMessages != null && assembledMessages.isNotEmpty) {
        if (opening) {
          // 开场：不给玩家输入，只加一条舞台指示，让角色先说话。
          requestMessages = [
            ...assembledMessages,
            {
              'role': 'system',
              'content': '（本幕刚开始：由你先开口，一两句即可，'
                  '贴合此刻的地点、时段与情绪；不要等玩家先说话）',
            },
          ];
        } else {
          // 预组装优先；组装方可能已经把它附在末尾了 —— 同一条不重复追加
          // （曾经因此把玩家那句话发过两遍）。
          final last = assembledMessages.last;
          final alreadyAppended =
              last['role'] == 'user' && last['content'] == userText;
          requestMessages = [
            ...assembledMessages,
            if (!alreadyAppended) {'role': 'user', 'content': userText},
          ];
        }
      } else {
        final history = messages
            .where((m) => m['is_system'] != true)
            .map((m) => {
                  'role': '${m['role'] ?? 'user'}',
                  'content': '${m['content'] ?? ''}',
                })
            .toList()
          ..add({'role': 'user', 'content': userText});
        requestMessages = [...history];
      }

      final result = await provider.generate(
        GenerateRequest(messages: requestMessages, stream: stream),
        cancel: token,
        onDelta: onDelta,
      );

      // Late / cancelled → no commit（闸门只有这一道，见类注释）
      if (token.isCancelled) {
        return TurnOutcome.rejected(
          'cancelled or superseded',
          world: world,
          messages: messages,
        );
      }
      if (!result.ok) {
        return TurnOutcome.rejected(
          result.error ?? 'provider failed',
          world: world,
          messages: messages,
          status: result.status,
        );
      }

      final ai = result.response!;
      var nextWorld = world;

      final turnId = 'turn_${startRev}_${DateTime.now().microsecondsSinceEpoch}';
      final assistantMessage = {
        'role': 'assistant',
        'content': ai.segments.map((s) => s.text).join('\n'),
        'segments': ai.segments.map((s) => s.toJson()).toList(),
        'turnId': turnId,
        if (audience.isNotEmpty) 'audience': audience,
      };
      final newMessages = [
        ...messages,
        // 开场没有玩家输入，只写回角色那一句
        if (!opening)
          {
            'role': 'user',
            'content': userText,
            'turnId': turnId,
            if (audience.isNotEmpty) 'audience': audience,
          },
        assistantMessage,
      ];

      _revision[sessionId] = startRev + 1;
      return TurnOutcome.committed(
        revision: _revision[sessionId]!,
        world: nextWorld,
        messages: newMessages,
        aiResponse: ai,
        // 把原始文本一起带出去：立绘/表情出问题时，日志里必须能看到
        // **模型究竟回了什么**，否则只能靠猜（复审指出的诊断缺口）。
        rawText: result.rawText,
      );
    } finally {
      _busy.remove(sessionId);
      if (identical(_active[sessionId], token)) {
        _active.remove(sessionId);
      }
    }
  }
}

class TurnOutcome {
  const TurnOutcome.committed({
    required this.revision,
    required this.world,
    required this.messages,
    required this.aiResponse,
    this.rawText,
  })  : accepted = true,
        error = null,
        status = ProviderStatus.ok;

  const TurnOutcome.rejected(
    this.error, {
    required this.world,
    required this.messages,
    this.status = ProviderStatus.invalid,
  })  : accepted = false,
        revision = 0,
        aiResponse = null,
        rawText = null;

  final bool accepted;
  final int revision;
  final WorldSnapshot world;
  final List<Map<String, Object?>> messages;
  final AIResponse? aiResponse;
  final String? error;
  final ProviderStatus status;

  /// 模型这一轮的**原始文本**（未解析）。立绘/表情排查全靠它。
  final String? rawText;
}
