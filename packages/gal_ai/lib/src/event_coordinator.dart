import 'package:gal_protocol/gal_protocol.dart';

export 'package:gal_protocol/gal_protocol.dart'
    show EventChoice, EventChoiceOption, EventDef, EventFrame, EventSlide,
        TargetBlock, ExitTarget;

/// Runtime state for playing an event.
class EventPlayState {
  const EventPlayState({
    required this.eventId,
    required this.eventVisitId,
    this.slideIndex = 0,
    this.storyVisitId = 0,
  });

  final String eventId;
  final int eventVisitId;

  /// 播到第几块（一格 = 一块 = 一屏，见 [EventDef.frames]）。
  final int slideIndex;

  /// 进入事件前的剧情访问号：事件收尾回剧情时要接着数，
  /// 否则 story visitId 归零重来，settlementIdFor 会和之前那次撞车。
  final int storyVisitId;

  Map<String, Object?> toJson() => {
        'mode': RuntimeCursor.modeEventPlay,
        'storyId': null,
        'visitId': storyVisitId,
        'eventId': eventId,
        'slideIndex': slideIndex,
        'eventVisitId': eventVisitId,
      };

  RuntimeCursor toCursor({String? storyId}) {
    return RuntimeCursor(
      mode: RuntimeCursor.modeEventPlay,
      storyId: storyId,
      visitId: storyVisitId,
      eventId: eventId,
      slideIndex: slideIndex,
      eventVisitId: eventVisitId,
    );
  }
}

/// 事件播放：逐格推进，播完交出一份收尾草稿（出口块由调用方按同一套
/// [TargetRouter] 规则判定）。
class EventCoordinator {
  EventCoordinator({required Map<String, EventDef> events})
      : _events = Map.unmodifiable(events);

  final Map<String, EventDef> _events;

  EventDef? event(String id) => _events[id];

  EventPlayState open({
    required String eventId,
    required int eventVisitId,
    int slideIndex = 0,
    int storyVisitId = 0,
  }) {
    final e = _events[eventId];
    if (e == null) {
      throw ArgumentError('unknown event $eventId');
    }
    final max = (e.frames.length - 1).clamp(0, 1 << 20);
    return EventPlayState(
      eventId: eventId,
      eventVisitId: eventVisitId,
      slideIndex: slideIndex.clamp(0, max),
      storyVisitId: storyVisitId,
    );
  }

  EventFrame? currentFrame(EventPlayState s) {
    final e = _events[s.eventId];
    if (e == null) return null;
    if (s.slideIndex < 0 || s.slideIndex >= e.frames.length) return null;
    return e.frames[s.slideIndex];
  }

  EventPlayState? advance(EventPlayState s) {
    final e = _events[s.eventId];
    if (e == null) return null;
    if (s.slideIndex + 1 >= e.frames.length) return null;
    return EventPlayState(
      eventId: s.eventId,
      eventVisitId: s.eventVisitId,
      slideIndex: s.slideIndex + 1,
      storyVisitId: s.storyVisitId,
    );
  }

  bool canFinish(EventPlayState s) {
    final e = _events[s.eventId];
    if (e == null) return false;
    return s.slideIndex >= e.frames.length - 1;
  }

  /// 这个事件有没有选择题出口。
  ///
  /// 有选择题时，最后一屏**不能靠「点一下结束」走人**：必须由玩家点某个选项，
  /// 出口就是那个选项写的目的地（不判数值、不随机）。
  EventChoice? choiceOf(EventPlayState s) {
    final e = _events[s.eventId];
    if (e == null) return null;
    final c = e.choice;
    return (c != null && c.options.isNotEmpty) ? c : null;
  }

  EventFinishDraft finish(EventPlayState s) {
    final e = _events[s.eventId];
    if (e == null) {
      throw ArgumentError('unknown event ${s.eventId}');
    }
    if (!canFinish(s)) {
      throw StateError('event not on last frame');
    }
    return EventFinishDraft(
      eventId: s.eventId,
      eventVisitId: s.eventVisitId,
      target: e.target,
      choice: choiceOf(s),
      commitId: 'ef_${s.eventId}_v${s.eventVisitId}_done',
    );
  }
}

class EventFinishDraft {
  const EventFinishDraft({
    required this.eventId,
    required this.eventVisitId,
    required this.target,
    required this.commitId,
    this.choice,
  });

  final String eventId;
  final int eventVisitId;

  /// 播完之后的出口块（与情景的 target 写法/判定完全一致）。
  final List<TargetBlock> target;

  /// 选择题出口（与 [target] 二选一）：非空时出口由玩家点选的选项决定。
  final EventChoice? choice;

  /// 收尾事务的幂等 id（由事件 id + 访问号拼成，访问号累计递增）。
  final String commitId;
}
