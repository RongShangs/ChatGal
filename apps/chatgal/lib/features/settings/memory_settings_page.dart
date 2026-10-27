import 'package:flutter/material.dart';
import 'package:gal_protocol/gal_protocol.dart';

import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';
import 'api_settings.dart';

/// 五层记忆阈值的设置页（从「设置」里单开一页，不再占用设置首页）。
///
/// 唯一的硬约束：**触发轮数必须大于保留轮数**（滑动时会互相顶开，
/// 最后由 `MemoryThresholds.normalized()` 兜底）。「每次压缩多少轮」不是独立设置 ——
/// 它就是「触发 − 保留」，凑一个独立滑条只会让三个值互相打架。
class MemorySettingsPage extends StatefulWidget {
  const MemorySettingsPage({
    super.key,
    required this.theme,
    required this.api,
    required this.initial,
    this.onChanged,
  });

  final ChatGalTheme theme;
  final ApiSettingsStore api;
  final AppSettings initial;
  final VoidCallback? onChanged;

  @override
  State<MemorySettingsPage> createState() => _MemorySettingsPageState();
}

class _MemorySettingsPageState extends State<MemorySettingsPage> {
  late AppSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.initial;
  }

  MemoryThresholds get _m => _settings.memory;

  Future<void> _set(MemoryThresholds next) async {
    final s = _settings.copyWith(memory: next.normalized());
    setState(() => _settings = s);
    await widget.api.update((current) => current.copyWith(memory: s.memory));
    widget.onChanged?.call();
  }

  /// 保留轮数：顶开触发轮数，保证「触发 > 保留」。
  Future<void> _setKeep(int v) => _set(
    _m.copyWith(
      l1KeepRounds: v,
      l1CollapseAt: _m.l1CollapseAt <= v ? v + 1 : _m.l1CollapseAt,
    ),
  );

  /// 触发轮数：如果压到保留线上，就把保留线一起压下去。
  Future<void> _setCollapseAt(int v) => _set(
    _m.copyWith(
      l1CollapseAt: v,
      l1KeepRounds: _m.l1KeepRounds >= v
          ? (v - 1).clamp(1, 400)
          : _m.l1KeepRounds,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final m = _m;
    return ChatGalShell(
      theme: t,
      title: '记忆（五层）',
      body: ListView(
        padding: const EdgeInsets.all(Spacing.md),
        children: [
          Text(
            '这些阈值只存在这里，存档不保存它们；改动在下次进入游戏时生效。'
            '游戏内的世界控制台只显示缓冲进度与各角色的记忆回廊。',
            style: TextStyle(fontSize: 11, color: t.sub, height: 1.5),
          ),
          const SizedBox(height: Spacing.md),
          _group(t, 'L1 活跃窗口（完整对话回合）', [
            _sliderRow(
              t,
              label: '坍缩后保留最近轮数',
              valueText: '${m.l1KeepRounds} 轮',
              value: m.l1KeepRounds.toDouble(),
              min: 1,
              max: 100,
              divisions: 99,
              onChanged: (v) => _setKeep(v.round()),
            ),
            _sliderRow(
              t,
              label: '达到多少轮触发坍缩',
              valueText: '${m.l1CollapseAt} 轮',
              value: m.l1CollapseAt.toDouble(),
              min: 2,
              max: 200,
              divisions: 198,
              onChanged: (v) => _setCollapseAt(v.round()),
            ),
            _derivedLine(
              t,
              '每次把最早 ${m.l1CollapseBatch} 轮压成 1 条 L2'
              '（= 触发 − 保留，不用单独设）',
            ),
          ]),
          _group(t, 'L2 片段记忆 → L3', [
            _sliderRow(
              t,
              label: '多少条触发升层',
              valueText: '${m.l2LiftCount} 条',
              value: m.l2LiftCount.toDouble(),
              min: 2,
              max: 30,
              divisions: 28,
              onChanged: (v) => _set(_m.copyWith(l2LiftCount: v.round())),
            ),
            _sliderRow(
              t,
              label: '每次升层合并多少条',
              valueText: '${m.l2LiftBatch} 条',
              value: m.l2LiftBatch.toDouble(),
              min: 1,
              max: 15,
              divisions: 14,
              onChanged: (v) => _set(_m.copyWith(l2LiftBatch: v.round())),
            ),
          ]),
          _group(t, 'L3 经历记忆 → L4', [
            _sliderRow(
              t,
              label: '多少条触发升层',
              valueText: '${m.l3LiftCount} 条',
              value: m.l3LiftCount.toDouble(),
              min: 2,
              max: 30,
              divisions: 28,
              onChanged: (v) => _set(_m.copyWith(l3LiftCount: v.round())),
            ),
            _sliderRow(
              t,
              label: '每次升层合并多少条',
              valueText: '${m.l3LiftBatch} 条',
              value: m.l3LiftBatch.toDouble(),
              min: 1,
              max: 15,
              divisions: 14,
              onChanged: (v) => _set(_m.copyWith(l3LiftBatch: v.round())),
            ),
            _sliderRow(
              t,
              label: '关键词记忆上限（L2→L3 时提取并合并/丢最旧）',
              valueText: '${m.l3KeywordMax} 条',
              value: m.l3KeywordMax.toDouble(),
              min: 4,
              max: 40,
              divisions: 36,
              onChanged: (v) => _set(_m.copyWith(l3KeywordMax: v.round())),
            ),
          ]),
          _group(t, 'L4 关系与行为趋势 → L5', [
            _sliderRow(
              t,
              label: '多少条送审 L5',
              valueText: '${m.l4LiftCount} 条',
              value: m.l4LiftCount.toDouble(),
              min: 2,
              max: 20,
              divisions: 18,
              onChanged: (v) => _set(_m.copyWith(l4LiftCount: v.round())),
            ),
            _sliderRow(
              t,
              label: '每次送审多少条',
              valueText: '${m.l4LiftBatch} 条',
              value: m.l4LiftBatch.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              onChanged: (v) => _set(_m.copyWith(l4LiftBatch: v.round())),
            ),
          ]),
          _group(t, 'L5 长期核心记忆', [
            _sliderRow(
              t,
              label: '进入上下文的上限',
              valueText: '${m.l5MaxChars} 字',
              value: m.l5MaxChars.toDouble(),
              min: 200,
              max: 5000,
              divisions: 48,
              onChanged: (v) =>
                  _set(_m.copyWith(l5MaxChars: (v / 100).round() * 100)),
            ),
            _sliderRow(
              t,
              label: '超限时一次合并最旧几条',
              valueText: '${m.l5CompressBatch} 条',
              value: m.l5CompressBatch.toDouble(),
              min: 2,
              max: 10,
              divisions: 8,
              onChanged: (v) => _set(_m.copyWith(l5CompressBatch: v.round())),
            ),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await _set(MemoryThresholds.defaults);
                if (!mounted) return;
                messenger.showSnackBar(
                  const SnackBar(content: Text('记忆阈值已恢复默认')),
                );
              },
              icon: Icon(Icons.restart_alt, size: 16, color: t.accent),
              label: Text(
                '恢复默认',
                style: TextStyle(color: t.accent, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(height: Spacing.lg),
        ],
      ),
    );
  }

  Widget _group(ChatGalTheme t, String title, List<Widget> rows) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: t.sub.withValues(alpha: 0.12)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.md,
            Spacing.sm,
            Spacing.md,
            2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
              const SizedBox(height: 4),
              ...rows,
            ],
          ),
        ),
      ),
    );
  }

  /// 只读的推导行：让「为什么没有第三个滑条」一眼看清楚。
  Widget _derivedLine(ChatGalTheme t, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Row(
        children: [
          Icon(Icons.functions, size: 13, color: t.sub),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11, color: t.sub, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sliderRow(
    ChatGalTheme t, {
    required String label,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: TextStyle(fontSize: 12, color: t.sub)),
            ),
            Text(
              valueText,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: t.accent,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          activeColor: t.accent,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
