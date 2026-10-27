import 'dart:convert';

import 'package:gal_protocol/gal_protocol.dart';

import 'memory_runtime.dart';
import 'settlement_evidence.dart';
import 'target_router.dart';

/// Provides settlement JSON for a scene leave (Mock or real AI).
///
/// The provider sees [SettlementEvidence] — the character's short-term memory
/// of this scene plus the known state — and never the raw scene transcript.
abstract class SettlementProvider {
  Future<SettlementProposal?> propose({
    required String sessionId,
    required SceneDef scene,
    required WorldSnapshot world,
    required SettlementEvidence evidence,
  });
}

/// Deterministic mock: returns fixed deltas or null (no evidence).
class MockSettlementProvider implements SettlementProvider {
  const MockSettlementProvider({this.deltas = const {}});

  final Map<String, int> deltas;

  @override
  Future<SettlementProposal?> propose({
    required String sessionId,
    required SceneDef scene,
    required WorldSnapshot world,
    required SettlementEvidence evidence,
  }) async {
    final filtered = <String, int>{};
    for (final b in scene.settlement) {
      if (deltas.containsKey(b.varId)) filtered[b.varId] = deltas[b.varId]!;
    }
    if (filtered.isEmpty) return null;
    return SettlementProposal(deltas: filtered);
  }
}

/// Result of a scene leave transition.
class TransitionResult {
  const TransitionResult.accepted({
    required this.world,
    required this.messages,
    required this.revision,
    required this.cursor,
    required this.nextSceneId,
    required this.appliedDeltas,
    required this.transitionId,
    this.appliedSettlementIds = const [],
    this.nextEventId,
    this.targetKind = 'story',
    this.memories,
    this.memoryNotes = const [],
  })  : accepted = true,
        noExit = false,
        error = null;

  const TransitionResult.rejected(
    this.error, {
    required this.world,
    required this.messages,
    this.revision = 0,
    this.memoryNotes = const [],
  })  : accepted = false,
        noExit = false,
        cursor = null,
        nextSceneId = null,
        nextEventId = null,
        targetKind = null,
        appliedDeltas = const {},
        transitionId = null,
        appliedSettlementIds = const [],
        memories = null;

  const TransitionResult.busy()
      : accepted = false,
        noExit = false,
        error = 'busy',
        world = null,
        messages = const [],
        revision = 0,
        cursor = null,
        nextSceneId = null,
        nextEventId = null,
        targetKind = null,
        appliedDeltas = const {},
        transitionId = null,
        appliedSettlementIds = const [],
        memories = null,
        memoryNotes = const [];

  /// 本情景**没有出口**（没写 target，或没有任何块的 require 成立）。
  /// 这不是错误：玩家留在原情景继续对话，界面提示「暂时不能进入下一阶段噢」。
  const TransitionResult.noExit({required this.world, required this.messages})
      : accepted = false,
        noExit = true,
        error = null,
        revision = 0,
        cursor = null,
        nextSceneId = null,
        nextEventId = null,
        targetKind = null,
        appliedDeltas = const {},
        transitionId = null,
        appliedSettlementIds = const [],
        memories = null,
        memoryNotes = const [];

  final bool accepted;
  final bool noExit;
  final String? error;
  final WorldSnapshot? world;
  final List<Map<String, Object?>> messages;
  final int revision;
  final RuntimeCursor? cursor;
  final String? nextSceneId;
  final String? nextEventId;
  final String? targetKind;
  final Map<String, int> appliedDeltas;
  final String? transitionId;

  /// Settlement ids this transition settled; the caller must persist them so a
  /// retry or a replay cannot apply the same settlement twice.
  final List<String> appliedSettlementIds;

  /// Draft memory bank after this transition's summary step (null when no
  /// memory runtime is wired). Only returned on accept — a rejected leave must
  /// not leave half-committed memory behind.
  final MemoryBank? memories;

  /// 这次换场里「记忆提炼没能用模型结果」的说明（超时/报错/输出无法解析时，
  /// L1 原文会由确定性拼接兜底记进 L2）。文案已经拼好，界面直接显示即可。
  final List<String> memoryNotes;
}

/// 换场过程中「玩家在等什么」的阶段。给界面做状态提示用。
///
/// 换场要等的是**两件设计上必须等的事**：本幕每个在场角色的 L1→L2 提炼，
/// 以及本幕的离场结算。更高层的整理（L2→L3→…）走后台阈值，不在这里。
enum LeavePhase {
  /// L1 → L2 提炼（每个在场角色一次请求）。
  memory,

  /// 离场结算（本幕所有受控变量合成一次请求）。
  settlement,

  /// 都完成了，界面可以收起提示。
  done,
}

/// Serial scene-leave coordinator: draft → all-or-nothing commit.
class TransitionCoordinator {
  TransitionCoordinator({
    required this.graph,
    this.settlement = const SettlementValidator(),
    this.registry = VariableRegistry.empty,
    this.memory,
    this.validator,
    TargetRouter? router,
  }) : router = router ?? TargetRouter();

  final SceneGraph graph;
  final SettlementValidator settlement;

  /// Optional memory runtime. Supplies the leave-path L1→L2 summary and the
  /// short-term evidence the settlement model may see. Higher-layer
  /// consolidation is **not** run here — it is decoupled from scene changes.
  final MemoryRuntime? memory;

  /// Declared variables. Supplies the flat namespace the world stores values in,
  /// and [VariableRegistry.ranges] as the final clamp.
  final VariableRegistry registry;

  /// Deterministic transition id — **no clock**. A retry of the same leave must
  /// reproduce the same id, otherwise `committedTransitions` cannot recognise
  /// it and the retry would settle a second time.
  static String transitionIdFor({
    required String sessionId,
    required int baseRevision,
    required String fromStoryId,
    required int fromVisitId,
  }) =>
      'tr_${sessionId}_${baseRevision}_${fromStoryId}_v$fromVisitId';

  /// Deterministic settlement id: **一幕一次**。同一情景的同一访问号重试
  /// （或崩溃后重放）命中已记账的 id 就跳过，不会再加一遍数值。
  static String settlementIdFor({
    required String sessionId,
    required String fromStoryId,
    required int fromVisitId,
  }) =>
      'sid_${sessionId}_${fromStoryId}_v$fromVisitId';

  /// Optional custom semantic checks.
  final bool Function(SceneDef scene)? validator;

  /// 出口判定（与事件共用同一套规则）。
  final TargetRouter router;

  final Map<String, bool> _busy = {};
  final Map<String, int> _revision = {};

  bool isBusy(String sessionId) => _busy[sessionId] == true;
  int revisionOf(String sessionId) => _revision[sessionId] ?? 0;

  /// Recover path: if pending id already committed, only clear residual.
  TransitionResult clearCommittedPending({
    required String sessionId,
    required WorldSnapshot world,
    required List<Map<String, Object?>> messages,
    required List<String> committedTransitions,
    required PendingOp? pending,
  }) {
    if (pending == null) {
      return TransitionResult.accepted(
        world: world,
        messages: messages,
        revision: revisionOf(sessionId),
        cursor: RuntimeCursor.fromJson(
          Map<String, Object?>.from(
            world.presentation['cursor'] as Map? ??
                {
                  'mode': 'storyChat',
                  'storyId': world.story['storyId'],
                  'visitId': 0,
                },
          ),
        ),
        nextSceneId: world.story['storyId'] as String?,
        appliedDeltas: const {},
        transitionId: '',
      );
    }
    if (committedTransitions.contains(pending.id)) {
      // Already committed — never roll back formal state.
      return TransitionResult.accepted(
        world: world,
        messages: messages,
        revision: revisionOf(sessionId),
        cursor: RuntimeCursor.fromJson(
          Map<String, Object?>.from(
            world.presentation['cursor'] as Map? ?? const {'mode': 'storyChat'},
          ),
        ),
        nextSceneId: world.story['storyId'] as String?,
        appliedDeltas: const {},
        transitionId: pending.id,
      );
    }
    return TransitionResult.rejected(
      'uncommitted pending ${pending.id}; draft discarded',
      world: world,
      messages: messages,
    );
  }

  /// Run leave transition for current storyId. Double-call while busy → busy.
  Future<TransitionResult> leaveCurrent({
    required String sessionId,
    required WorldSnapshot world,
    required List<Map<String, Object?>> messages,
    required int baseRevision,
    required SettlementProvider provider,
    List<String> committedTransitions = const [],
    List<String> appliedSettlementIds = const [],
    MemoryBank? bank,
    RuntimeCursor? cursor,
    void Function(LeavePhase phase, int done, int total, String? owner)?
        onProgress,
  }) async {
    final memoryNotes = <String>[];
    if (_busy[sessionId] == true) {
      return TransitionResult.busy();
    }
    _busy[sessionId] = true;
    try {
      final fromStoryId = (cursor?.storyId ?? world.story['storyId']) as String?;
      final fromVisitId = cursor?.visitId ?? 0;
      if (fromStoryId == null) {
        return TransitionResult.rejected('no current story',
            world: world, messages: messages);
      }
      final transitionId = transitionIdFor(
        sessionId: sessionId,
        baseRevision: baseRevision,
        fromStoryId: fromStoryId,
        fromVisitId: fromVisitId,
      );
      final scene = graph.scene(fromStoryId);
      if (scene == null) {
        return TransitionResult.rejected('scene $fromStoryId not found',
            world: world, messages: messages);
      }
      if (validator != null && !validator!(scene)) {
        return TransitionResult.rejected('scene validator failed',
            world: world, messages: messages);
      }
      // 没有出口块 = 合法的「到此为止」情景：不换幕、不报错。
      if (scene.target.isEmpty) {
        return TransitionResult.noExit(world: world, messages: messages);
      }

      // --- Step 2: summarize this scene's memory (L1 → L2) --------------
      // Runs on a **clone** of the bank so a rejected leave leaves no
      // half-committed memory behind (all-or-nothing).
      final audience = <String>[
        for (final c in scene.characters)
          if (c.charId.isNotEmpty) c.charId,
      ];
      final dayBeforeLeave = (world.variables['day'] as num?)?.toInt() ??
          (world.story['day'] as num?)?.toInt() ??
          0;
      // 「玩家要等几步」：本幕每个在场角色一次提炼 + 需要时一次结算。
      // 先算出来是为了让界面**一开始就能给出总步数**（进度条要有个分母）。
      final settleSid = settlementIdFor(
        sessionId: sessionId,
        fromStoryId: fromStoryId,
        fromVisitId: fromVisitId,
      );
      final willSettle =
          scene.settlement.isNotEmpty && !appliedSettlementIds.contains(settleSid);
      var progressDone = 0;
      var progressTotal = willSettle ? 1 : 0;
      MemoryBank? draftBank;
      // 结算证据要在**提炼之前**取：提炼会把本场景的 L1 轮次换成 L2 摘要，
      // 之后再取就只有摘要、原文细节全没了。这份快照只给证据用。
      // 注意：fromJson 默认 thresholds=defaults，克隆时必须显式传入当前阈值，
      // 否则 replaceWith 会把默认阈值覆盖回正式记忆（玩家自定义设置被重置）。
      final evidenceBank = bank == null
          ? null
          : MemoryBank.fromJson(bank.toJson(), thresholds: bank.thresholds);
      if (bank != null) {
        draftBank =
            MemoryBank.fromJson(bank.toJson(), thresholds: bank.thresholds);
        if (memory != null) {
          // 要整理的 owner = 本幕在场角色 ∪ 窗口里还有轮次的角色。
          // 只看在场角色会漏掉「窗口里留着但不在本幕 characters 表」的那些，
          // 它们的 L1 就会被带进下一幕。
          final owners = <String>{
            ...audience,
            for (final o in draftBank.owners)
              if (draftBank.windowIfExists(o)?.turns.isNotEmpty == true) o,
          }.toList();
          progressTotal += owners.length;
          onProgress?.call(LeavePhase.memory, progressDone, progressTotal, null);
          for (final owner in owners) {
            // 离场统一做「本幕 L1 提炼成一条 L2」：提炼成功才放行。失败就留在
            // 本幕重试 —— 不能把没整理过的原始对话丢掉（那是静默丢记忆），
            // 也不能带进下一幕串味。高层整理只走后台阈值，不阻塞换场。
            final plan = await memory!.planSceneSummary(
              bank: draftBank,
              owner: owner,
              storyId: fromStoryId,
              visitId: fromVisitId,
              facts: {'day': dayBeforeLeave},
            );
            if (plan == null) {
              // 本幕已提炼过 / 本来就没有轮次：这一步不需要等，但进度照样往前走。
              progressDone++;
              onProgress?.call(
                LeavePhase.memory,
                progressDone,
                progressTotal,
                owner,
              );
              continue;
            }
            if (plan.isEmpty) {
              return TransitionResult.rejected(
                '本幕记忆还没整理完：${plan.failure ?? '原因未知'}。'
                '本幕对话原样保留，可再试一次',
                world: world,
                messages: messages,
              );
            }
            // 兜底路径：模型没给出可用摘要（超时/报错/输出无法解析），L2 记的是
            // 原文拼接。这里留下一句人话，界面与日志才看得出为什么。
            if (plan.usedFallback) {
              memoryNotes.add(
                '$owner 的本幕记忆没能提炼'
                '（${plan.fallbackReason ?? '原因未知'}），已按原文记下',
              );
            }
            memory!.commitCollapse(draftBank, plan);
            progressDone++;
            onProgress?.call(
              LeavePhase.memory,
              progressDone,
              progressTotal,
              owner,
            );
          }
        }
      }

      // --- Step 4: AI settlement proposal -------------------------------
      // 本幕声明的**每个受控变量一个块**（各自的判定提示词与单次上限），
      // 但仍然只发**一次**请求：把所有块的说明拼在一起，让模型一次给出全部增量，
      // 每个增量按它自己那条块的上限收口。变量都住在扁平命名空间里。
      var applied = <String, int>{};
      final newSettlementIds = <String>[];
      final settlementBlocks = scene.settlement;
      if (settlementBlocks.isNotEmpty) {
        final sid = settleSid;
        // Idempotence: this scene visit was already settled — a retry or a
        // crash replay must not add the numbers again.
        if (!appliedSettlementIds.contains(sid)) {
          onProgress?.call(
            LeavePhase.settlement,
            progressDone,
            progressTotal,
            null,
          );
          final controlled = <String>[for (final b in settlementBlocks) b.varId];
          final state = <String, Object?>{
            for (final v in controlled) v: world.variables[v],
          };
          final owner = audience.isNotEmpty ? audience.first : '';
          // Evidence is the character's **short-term** memory of this scene
          // (L1窗口 + L2 片段) plus the known state — never the raw transcript.
          final evidence = (evidenceBank == null || memory == null)
              ? SettlementEvidence(
                  owner: owner,
                  sceneId: scene.id,
                  sceneName: scene.displayName,
                  day: dayBeforeLeave,
                  shortTerm: const [],
                  state: state,
                  audience: audience,
                )
              : memory!.buildEvidence(
                  bank: evidenceBank,
                  owner: owner,
                  scene: scene,
                  visitId: fromVisitId,
                  day: dayBeforeLeave,
                  audience: audience,
                  state: state,
                );
          final proposal = await provider.propose(
            sessionId: sessionId,
            scene: scene,
            world: world,
            evidence: evidence,
          );
          if (proposal == null) {
            // 模型啥也没给（或解析失败）：只要有一个变量声明了 abort，就整笔拒绝、
            // 保留原情景可重试；否则这些变量都保持原值。
            if (settlementBlocks.any((b) => b.onNoEvidence == 'abort')) {
              return TransitionResult.rejected(
                'settlement no evidence abort (${scene.id})',
                world: world,
                messages: messages,
              );
            }
          } else {
            // 逐项检查 abort：某个必需变量在 proposal 里缺失时也要拒绝，
            // 不能因为「整个 proposal 不是 null」就放行（以前只有整体为 null
            // 才触发 abort，模型给了其他变量却漏了 abort 变量时会静默放行）。
            final missingAbort = <String>[
              for (final b in settlementBlocks)
                if (b.onNoEvidence == 'abort' &&
                    !proposal.deltas.containsKey(b.varId))
                  b.varId,
            ];
            if (missingAbort.isNotEmpty) {
              return TransitionResult.rejected(
                'settlement abort：${missingAbort.join('、')} 没有证据'
                '（onNoEvidence=abort）(${scene.id})',
                world: world,
                messages: messages,
              );
            }
            final current = <String, int>{
              for (final v in controlled)
                if (world.variables[v] is num)
                  v: (world.variables[v] as num).toInt(),
            };
            final Map<String, int> clampedDeltas;
            try {
              clampedDeltas = settlement.apply(
                proposal: proposal,
                allowedVars: controlled.toSet(),
                maxAbsDeltaPerVar: {
                  for (final b in settlementBlocks) b.varId: b.maxAbsDelta,
                },
                currentValues: current,
                ranges: registry.ranges,
              );
            } on SettlementValidationError catch (e) {
              // 模型给了本幕之外的变量名 —— 整笔离场作废、原场景保留可重试，
              // 而不是让异常逃出去（那会留下 pending 残骸）。
              return TransitionResult.rejected(
                '结算被拒（${scene.id}）：${e.message}',
                world: world,
                messages: messages,
              );
            }
            applied = clampedDeltas;
            newSettlementIds.add(sid);
          }
        }
      }

      // 提炼与结算都过去了：界面可以收起「正在整理」的提示。
      progressDone = progressTotal;
      onProgress?.call(LeavePhase.done, progressDone, progressTotal, null);

      // Character map is no longer the stat store; keep the copy for the
      // appearance/derived fields that still live there.
      final nextChars = <String, Map<String, Object?>>{
        for (final e in world.characters.entries)
          e.key: Map<String, Object?>.from(e.value),
      };

      // Apply deltas into the flat namespace, clamped by the registered bounds.
      // 按变量类型处理精度：int 向零取整、number 保留小数。
      var nextVars = Map<String, Object?>.from(world.variables);
      if (applied.isNotEmpty) {
        applied.forEach((id, d) {
          final def = registry[id];
          final type = def?.type ?? 'number';
          nextVars[id] = applySettlementDelta(
            nextVars[id],
            d,
            type: type,
            min: def?.min,
            max: def?.max,
          );
        });
      }

      // --- Exit judgment inside the story -------------------------------
      // 出口块按数组顺序求值，**首个 require 成立**的块被锁定；块内等概率取一个。
      // 判定读结算后的值；`day` 就是本情景所属的那一天（day+1 写在**下一个**
      // 情景的入场 fixedEffects 上，此刻还没应用，所以不需要额外快照）。
      final exitEval = world.copyWith(
        variables: nextVars,
        characters: nextChars,
        story: {...world.story, 'day': nextVars['day']},
      );
      final chosen = router.route(
        scene.target,
        exitEval,
        rngState: world.rngState,
      );

      if (chosen == null) {
        // 所有块的 require 都不成立 —— 和「压根没有出口」同一种结果：留在原地。
        return TransitionResult.noExit(world: world, messages: messages);
      }
      final routeKind = chosen.kind;
      final routeTo = chosen.to;

      if (routeKind == 'event') {
        // 事件访问号**累计递增**（不是每次从 1 开始）：事件的 commitId 由它拼成，
        // 恒为 1 会让「同一事件第二次被走到」与第一次同 id —— 幂等台账、
        // 事件结束效果都会互相干扰。
        final nextEventVisit = (cursor?.eventVisitId ?? 0) + 1;
        final nextCursor = RuntimeCursor(
          mode: RuntimeCursor.modeEventPlay,
          storyId: null,
          // 记着「我是从哪一次剧情访问进事件的」：事件收尾回剧情时要接着数，
          // 否则 story visitId 归零重来，settlementIdFor 会和之前那次撞车、
          // 结算被幂等台账当成"已结算"而**静默不加数值**。
          visitId: fromVisitId,
          eventId: routeTo,
          slideIndex: 0,
          eventVisitId: nextEventVisit,
        );
        final nextWorld = WorldSnapshot(
          variables: nextVars,
          characters: nextChars,
          eventHistory: world.eventHistory,
          story: Map<String, Object?>.from(world.story)
            ..['day'] = nextVars['day'],
          presentation: {
            ...world.presentation,
            'cursor': nextCursor.toJson(),
            'pendingEvent': routeTo,
          },
          rngState: world.rngState + 1,
        );
        final newMessages = [
          ...messages,
          {
            'role': 'system',
            'is_system': true,
            'content': '【事件】$routeTo',
          },
        ];
        final nextRev = baseRevision + 1;
        _revision[sessionId] = nextRev;
        return TransitionResult.accepted(
          world: nextWorld,
          messages: newMessages,
          revision: nextRev,
          cursor: nextCursor,
          nextSceneId: null,
          nextEventId: routeTo,
          targetKind: 'event',
          appliedDeltas: applied,
          transitionId: transitionId,
          appliedSettlementIds: newSettlementIds,
          memories: draftBank,
          memoryNotes: memoryNotes,
        );
      }

      if (routeKind == 'appShell') {
        final nextWorld = WorldSnapshot(
          variables: nextVars,
          characters: nextChars,
          eventHistory: world.eventHistory,
          story: Map<String, Object?>.from(world.story)
            ..['day'] = nextVars['day'],
          presentation: {...world.presentation, 'returnHome': true},
          rngState: world.rngState + 1,
        );
        final nextRev = baseRevision + 1;
        _revision[sessionId] = nextRev;
        return TransitionResult.accepted(
          world: nextWorld,
          messages: messages,
          revision: nextRev,
          cursor: _cursorFrom(world, null, fromVisitId),
          nextSceneId: null,
          nextEventId: null,
          targetKind: 'appShell',
          appliedDeltas: applied,
          transitionId: transitionId,
          appliedSettlementIds: newSettlementIds,
          memories: draftBank,
          memoryNotes: memoryNotes,
        );
      }

      if (routeKind != 'story') {
        return TransitionResult.rejected(
          'unsupported route kind $routeKind',
          world: world,
          messages: messages,
        );
      }
      final nextScene = graph.scene(routeTo);
      if (nextScene == null) {
        return TransitionResult.rejected(
          'target $routeTo missing',
          world: world,
          messages: messages,
        );
      }

      // --- Draft: enter ---
      applyVariableChanges(
        nextVars,
        nextScene.fixedEffects,
        registry: registry,
      );
      final nextVisit = fromVisitId + 1;
      final nextCursor = RuntimeCursor(
        mode: RuntimeCursor.modeStoryChat,
        storyId: nextScene.id,
        visitId: nextVisit,
        // 事件访问号一路带着走：回到剧情再进事件时还要接着数。
        eventVisitId: cursor?.eventVisitId,
      );
      final nextPresentation = {
        ...world.presentation,
        'scene': nextScene.background ?? world.presentation['scene'],
        'narration': nextScene.narration,
        'actors': nextScene.characters.map((a) => a.toJson()).toList(),
        'cursor': nextCursor.toJson(),
      };

      final storyState = Map<String, Object?>.from(world.story)
        ..['storyId'] = nextScene.id
        ..['day'] = nextVars['day'];

      final nextWorld = WorldSnapshot(
        variables: nextVars,
        characters: nextChars,
        eventHistory: world.eventHistory,
        story: storyState,
        presentation: nextPresentation,
        rngState: world.rngState + 1,
      );

      final newMessages = [
        ...messages,
        {
          'role': 'system',
          'is_system': true,
          'content':
              '第${nextVars['day'] ?? '?'}天 · ${nextScene.displayName}\n${nextScene.narration}',
        },
      ];

      // Commit
      final nextRev = baseRevision + 1;
      _revision[sessionId] = nextRev;
      return TransitionResult.accepted(
        world: nextWorld,
        messages: newMessages,
        revision: nextRev,
        cursor: nextCursor,
        nextSceneId: nextScene.id,
        appliedDeltas: applied,
        transitionId: transitionId,
        appliedSettlementIds: newSettlementIds,
        memories: draftBank,
      );
    } finally {
      _busy[sessionId] = false;
    }
  }

  RuntimeCursor _cursorFrom(
    WorldSnapshot world,
    String? storyId,
    int visitId,
  ) {
    return RuntimeCursor.fromJson(
      Map<String, Object?>.from(
        world.presentation['cursor'] as Map? ??
            {
              'mode': 'storyChat',
              'storyId': storyId ?? world.story['storyId'],
              'visitId': visitId,
            },
      ),
    );
  }

}

/// Encode pending for save checkpoint.
String encodePending(PendingOp? p) =>
    p == null ? '' : jsonEncode(p.toJson());
