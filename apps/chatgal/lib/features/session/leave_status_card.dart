import 'package:flutter/material.dart';
import 'package:gal_ai/gal_ai.dart';

import '../../design_system/tokens.dart';

/// 换场等待期的状态：换场要等「本幕每个在场角色的 L1→L2 提炼」与「离场结算」，
/// 这两件事都是设计上必须等的（记忆不能没整理完就带进下一幕）。
@immutable
class LeaveStatus {
  const LeaveStatus({
    this.phase = LeavePhase.memory,
    this.done = 0,
    this.total = 0,
    this.owner,
    this.seconds = 0,
  });

  /// 当前阶段。
  final LeavePhase phase;

  /// 已经走完几步、一共几步（`total == 0` = 还不知道要几步）。
  final int done;
  final int total;

  /// 正在整理哪个角色（记忆阶段才有）。
  final String? owner;

  /// 已经等了多久（秒）。
  final int seconds;

  LeaveStatus copyWith({
    LeavePhase? phase,
    int? done,
    int? total,
    String? owner,
    int? seconds,
  }) => LeaveStatus(
    phase: phase ?? this.phase,
    done: done ?? this.done,
    total: total ?? this.total,
    owner: owner ?? this.owner,
    seconds: seconds ?? this.seconds,
  );
}

/// 换场等待期那块小卡：画面中上部，一句人话 + 进度条 + 已等待秒数。
///
/// 两条刻意的设计：
/// * 进度条是**真分步**（本幕要提炼几个角色 + 要不要结算），不是按时间假推进；
///   步数还不知道时干脆不画进度条，只显示「已等待 N 秒」。
/// * **不放无限旋转的指示器**：等待期本来就长，无限动画会让「等它转完」的
///   测试永远 settle 不了；这里所有视觉都在一帧内静态。
class LeaveStatusCard extends StatelessWidget {
  const LeaveStatusCard({
    super.key,
    required this.status,
    required this.theme,
  });

  final LeaveStatus status;
  final ChatGalTheme theme;

  String get _label => switch (status.phase) {
    LeavePhase.memory => status.owner == null
        ? '正在整理本幕的记忆'
        : '正在整理本幕的记忆（${status.owner}）',
    LeavePhase.settlement => '正在结算本幕的变化',
    LeavePhase.done => '正在进入下一幕',
  };

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final total = status.total;
    return Container(
      key: const ValueKey('leave-status-card'),
      constraints: const BoxConstraints(maxWidth: 300),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 11),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.sub.withValues(alpha: 0.18)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 14, color: t.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: t.ink,
                  ),
                ),
              ),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: (status.done / total).clamp(0.0, 1.0),
                backgroundColor: t.sub.withValues(alpha: 0.15),
                color: t.accent,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            total > 0
                ? '第 ${status.done}/$total 步 · 已等待 ${status.seconds} 秒'
                : '已等待 ${status.seconds} 秒',
            style: TextStyle(fontSize: 11, color: t.sub),
          ),
        ],
      ),
    );
  }
}
