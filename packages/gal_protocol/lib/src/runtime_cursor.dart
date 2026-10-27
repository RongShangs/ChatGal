/// Runtime cursor (single authority for current position).
class RuntimeCursor {
  const RuntimeCursor({
    this.mode = 'storyChat',
    this.storyId,
    this.visitId = 0,
    this.eventId,
    this.slideIndex,
    this.eventVisitId,
  });

  static const modeStoryChat = 'storyChat';
  static const modeEventPlay = 'eventPlay';

  final String mode;
  final String? storyId;
  final int visitId;
  final String? eventId;
  final int? slideIndex;
  final int? eventVisitId;

  RuntimeCursor copyWith({
    String? mode,
    String? storyId,
    int? visitId,
    String? eventId,
    int? slideIndex,
    int? eventVisitId,
    bool clearEvent = false,
  }) {
    return RuntimeCursor(
      mode: mode ?? this.mode,
      storyId: storyId ?? this.storyId,
      visitId: visitId ?? this.visitId,
      eventId: clearEvent ? null : (eventId ?? this.eventId),
      slideIndex: clearEvent ? null : (slideIndex ?? this.slideIndex),
      eventVisitId:
          clearEvent ? null : (eventVisitId ?? this.eventVisitId),
    );
  }

  Map<String, Object?> toJson() => {
        'mode': mode,
        'storyId': storyId,
        'visitId': visitId,
        'eventId': eventId,
        'slideIndex': slideIndex,
        'eventVisitId': eventVisitId,
      };

  factory RuntimeCursor.fromJson(Map<String, Object?> json) {
    return RuntimeCursor(
      mode: (json['mode'] as String?) ?? modeStoryChat,
      storyId: json['storyId'] as String?,
      visitId: (json['visitId'] as num?)?.toInt() ?? 0,
      eventId: json['eventId'] as String?,
      slideIndex: (json['slideIndex'] as num?)?.toInt(),
      eventVisitId: (json['eventVisitId'] as num?)?.toInt(),
    );
  }
}

/// Pending write-queue operation (collapse | storyTransition | eventFinish).
class PendingOp {
  const PendingOp({
    required this.kind,
    required this.id,
    required this.baseRevision,
    this.phase = 'drafting',
    this.cache = const {},
  });

  static const kindCollapse = 'collapse';
  static const kindStoryTransition = 'storyTransition';
  static const kindEventFinish = 'eventFinish';

  final String kind;
  final String id;
  final int baseRevision;
  final String phase;
  final Map<String, Object?> cache;

  bool get isCommittedResidual => phase == 'committed_residual';

  Map<String, Object?> toJson() => {
        'kind': kind,
        'id': id,
        'baseRevision': baseRevision,
        'phase': phase,
        'cache': cache,
      };

  factory PendingOp.fromJson(Map<String, Object?> json) {
    return PendingOp(
      kind: json['kind']! as String,
      id: json['id']! as String,
      baseRevision: (json['baseRevision']! as num).toInt(),
      phase: (json['phase'] as String?) ?? 'drafting',
      cache: Map<String, Object?>.from(json['cache'] as Map? ?? {}),
    );
  }
}
