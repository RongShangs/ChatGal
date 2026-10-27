import 'package:flutter/material.dart';
import 'package:gal_protocol/gal_protocol.dart';

import '../../design_system/shell.dart';
import '../../design_system/tokens.dart';

/// 世界控制台：记忆参数 / 回复长度 / 立绘大小 + 数值（包内注册变量）+ 事件收集
class MemoryPage extends StatefulWidget {
  const MemoryPage({
    super.key,
    required this.theme,
    required this.l1Count,
    required this.l1Capacity,
    required this.l1KeepRounds,
    required this.cascadeState,
    required this.registry,
    required this.worldValues,
    required this.events,
    required this.triggeredEventIds,
    this.characters = const [],
    this.onOpenMemoryTree,
  });

  final ChatGalTheme theme;
  /// L1 活跃窗口里的对话轮数（记忆缓冲直接按它显示）。
  final int l1Count;
  final int l1Capacity;
  final int l1KeepRounds;
  final String? cascadeState;

  /// 包内注册的变量（系统 + 角色），数值区按它渲染——不写死任何角色数值。
  final VariableRegistry registry;

  /// 这些变量的当前值。
  final Map<String, Object?> worldValues;

  /// 包内的全部事件（事件收集区，未触发的显示为灰色方块）。
  final List<EventDef> events;
  final Set<String> triggeredEventIds;

  /// 包内声明的角色（= characters/ 下的文件夹数）：每个角色一个记忆回廊入口。
  final List<CharacterDef> characters;

  final ValueChanged<String>? onOpenMemoryTree;

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  Widget _flatPanel(ChatGalTheme t, {required Widget child}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: t.sub.withValues(alpha: 0.12)),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    // 除零保护：阈值来自设置，理论上已被 normalized() 夹到 ≥2，这里再挡一层。
    final ratio = widget.l1Capacity <= 0
        ? 0.0
        : (widget.l1Count / widget.l1Capacity).clamp(0.0, 1.0);

    return ChatGalShell(
      theme: t,
      title: '世界控制台',
      body: ListView(
        padding: const EdgeInsets.all(Spacing.md),
        children: [
          Text(
            '记忆缓冲与角色回廊',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: t.accent,
            ),
          ),
          const SizedBox(height: 10),
          _flatPanel(
            t,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '记忆缓冲',
                    style: TextStyle(fontSize: 12, color: t.sub),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 6,
                      backgroundColor: t.sub.withValues(alpha: 0.15),
                      color: ratio >= 1 ? Colors.redAccent : t.accent,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.cascadeState ??
                        '缓冲 ${widget.l1Count}/${widget.l1Capacity}'
                            '（到点坍缩，之后保留最近 ${widget.l1KeepRounds} 轮）',
                    style: TextStyle(
                      fontSize: 11,
                      color: widget.cascadeState != null
                          ? t.accent
                          : t.sub,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '阈值在「设置 → 记忆（五层）」里调整',
                    style: TextStyle(fontSize: 11, color: t.sub),
                  ),
                  const SizedBox(height: 14),
                  if (widget.characters.isNotEmpty) ...[
                    Text('角色记忆回廊',
                        style: TextStyle(fontSize: 11, color: t.sub)),
                    const SizedBox(height: 4),
                    for (final c in widget.characters)
                      _memoryCorridor(t, c),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: Spacing.lg),
          Text(
            '数值',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: t.accent,
            ),
          ),
          const SizedBox(height: 10),
          _flatPanel(
            t,
            child: Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _buildValues(t),
              ),
            ),
          ),
          const SizedBox(height: Spacing.lg),
          Text(
            '事件收集  已触发 ${widget.triggeredEventIds.length} / 总数 ${widget.events.length}',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: t.accent,
            ),
          ),
          const SizedBox(height: 10),
          _flatPanel(
            t,
            child: Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: _buildEvents(t),
            ),
          ),
        ],
      ),
    );
  }

  /// 数值区：按包内注册表渲染。系统变量一组，每个角色一组。
  /// 变量名、上下限、role 全部来自 manifest，应用不写死任何角色数值。
  List<Widget> _buildValues(ChatGalTheme t) {
    final reg = widget.registry;
    if (reg.isEmpty) {
      return [
        Text('这个包没有注册任何变量。',
            style: TextStyle(fontSize: 12, color: t.sub)),
      ];
    }
    final out = <Widget>[];

    /// 变量按角色 id 分组，而角色 id 同时就是它的显示名（两者已合并）。
    String labelOf(String id) => id;

    void section(String title, List<VariableDef> defs) {
      if (defs.isEmpty) return;
      if (out.isNotEmpty) out.add(const SizedBox(height: 14));
      out.add(Text(title,
          style: TextStyle(
              fontSize: 12, color: t.sub, fontWeight: FontWeight.w700)));
      out.addAll(defs.map((v) => _valueRow(t, v)));
    }

    section('系统', reg.defs.where((v) => reg.ownerOf(v.id) == null).toList());
    for (final owner in reg.charIds) {
      section('角色：${labelOf(owner)}', reg.varsOf(owner));
    }
    return out;
  }

  Widget _valueRow(ChatGalTheme t, VariableDef v) {
    final raw = widget.worldValues[v.id];
    final min = v.min;
    final max = v.max;
    final showBar = raw is num && min != null && max != null && max > min;
    final ratio = showBar
        ? ((raw - min) / (max - min)).clamp(0.0, 1.0).toDouble()
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  v.label ?? v.id,
                  style: TextStyle(fontSize: 13, color: t.ink),
                ),
              ),
              Text(
                raw == null ? '—' : '$raw',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: t.accent,
                ),
              ),
            ],
          ),
          if (showBar) ...[
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 4,
                backgroundColor: t.sub.withValues(alpha: 0.18),
                valueColor: AlwaysStoppedAnimation<Color>(t.accent),
              ),
            ),
          ],
          const SizedBox(height: 3),
          Text(
            '${v.id}　${v.type}'
            '${min != null && max != null ? '　$min–$max' : ''}',
            style: TextStyle(fontSize: 10.5, color: t.sub),
          ),
        ],
      ),
    );
  }

  /// 事件收集：未触发是灰色正方块，触发后显现事件名。
  Widget _buildEvents(ChatGalTheme t) {
    if (widget.events.isEmpty) {
      return Text('这个包没有事件。', style: TextStyle(fontSize: 12, color: t.sub));
    }
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [for (final e in widget.events) _eventTile(t, e)],
    );
  }

  Widget _eventTile(ChatGalTheme t, EventDef e) {
    final on = widget.triggeredEventIds.contains(e.id);
    return SizedBox(
      width: 92,
      height: 92,
      child: Container(
        decoration: BoxDecoration(
          color: on
              ? t.accent.withValues(alpha: 0.16)
              : t.sub.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: on ? t.accent : t.sub.withValues(alpha: 0.30),
            width: on ? 1.2 : 0.8,
          ),
        ),
        padding: const EdgeInsets.all(8),
        child: Center(
          child: Text(
            on ? e.id : '未触发',
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: on ? 13 : 11,
              fontWeight: on ? FontWeight.w700 : FontWeight.w400,
              color: on ? t.ink : t.sub,
            ),
          ),
        ),
      ),
    );
  }

  /// 一个角色的记忆回廊入口：紫色块里直接就是角色名字（有几个角色就有几个块）。
  Widget _memoryCorridor(ChatGalTheme t, CharacterDef c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: t.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: widget.onOpenMemoryTree == null
              ? null
              : () => widget.onOpenMemoryTree!(c.id),
          child: SizedBox(
            height: 48,
            child: Center(
              child: Text(
                c.id,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: t.accent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

}

/// 单个角色的五层记忆树（入口来自世界控制台的「xx角色的记忆回廊」）。
/// 每个角色一棵独立的树 + 自己的 L1 活跃窗口。
class MemoryTreePage extends StatelessWidget {
  const MemoryTreePage({
    super.key,
    required this.theme,
    required this.bank,
    required this.owner,
    required this.ownerName,
  });

  final ChatGalTheme theme;
  final MemoryBank bank;
  final String owner;
  final String ownerName;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    return ChatGalShell(
      theme: t,
      title: '$ownerName角色的记忆回廊',
      body: ListView(
        padding: const EdgeInsets.all(Spacing.md),
        children: _ownerSection(t, owner),
      ),
    );
  }

  List<Widget> _ownerSection(ChatGalTheme t, String owner) {
    final tree = bank.treeOf(owner);
    final window = bank.windowOf(owner);

    String text(List<MemoryEntry> list, String empty) => list.isEmpty
        ? empty
        : list
            .map((e) {
              final scenes = e.sourceScenes
                  .map((s) => '${s['storyId']}')
                  .where((s) => s.isNotEmpty && s != 'null')
                  .toSet()
                  .join('、');
              final src = scenes.isEmpty ? '' : '  〔来源：$scenes〕';
              return '- ${e.text}$src';
            })
            .join('\n');

    return [
      if (window.length > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 4),
          child: Text(
            'L1 活跃窗口　${window.length} 轮',
            style: TextStyle(
              color: t.accent,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      _layerCard(
        t,
        title: '【Layer 5】长期核心记忆',
        titleColor: t.accent,
        body: text(tree.injectable(5), '暂无核心记忆（证据不足时不会硬造）。'),
      ),
      _layerCard(
        t,
        title: '【Layer 4】关系与行为趋势',
        body: text(tree.injectable(4), '尚无稳定趋势。'),
      ),
      _layerCard(
        t,
        title: '【Layer 3】经历记忆',
        body: text(tree.injectable(3), '暂无经历提炼。'),
      ),
      _layerCard(
        t,
        title: '【Layer 2】片段记忆',
        body: text(tree.injectable(2), '暂无片段摘要。'),
      ),
      _layerCard(
        t,
        title: '【Layer 1】活跃对话窗口（${window.length} 轮）',
        body: window.turns.isEmpty
            ? '窗口为空（本幕已提炼）。完整聊天记录仍在存档里，可回看。'
            : window.turns
                .map((x) => '〔${x.storyId}〕玩家：${x.playerText}\n${x.replyText}')
                .join('\n\n'),
      ),
      _keywordCard(t, tree.keywordEvents),
    ];
  }

  /// 关键词记忆卡：**只显示会触发的关键词**，不显示背后的内容。
  ///
  /// 内容不进回廊是刻意的 —— 它的用途是「被提到时唤起角色的认知」，
  /// 铺出来只会把一屏塞满细节，让记忆回廊变成第二个聊天记录。
  Widget _keywordCard(ChatGalTheme t, List<Map<String, Object?>> events) {
    // 玫红：和上面五层的紫色系分开，一眼看出这是并行通道而不是第六层。
    final accent = t.brightness == Brightness.dark
        ? const Color(0xFFFF9BB0)
        : const Color(0xFFD84A6A);

    // 一条记忆 = 一组关键词（同组的词指向同一件事），组内顺序就是模型给的顺序。
    final groups = <List<String>>[];
    final audience = <String>{};
    for (final ev in events) {
      final keys = (ev['keywords'] as List? ?? const [])
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (keys.isNotEmpty) groups.add(keys);
      for (final a in ev['audience'] as List? ?? const []) {
        final s = '$a'.trim();
        if (s.isNotEmpty) audience.add(s);
      }
    }
    final words = groups.fold<int>(0, (n, g) => n + g.length);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      decoration: BoxDecoration(
        color: accent.withValues(
          alpha: t.brightness == Brightness.dark ? 0.12 : 0.06,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.vpn_key_rounded, size: 15, color: accent),
              const SizedBox(width: 6),
              Text(
                '【关键词记忆】提到才想起来',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: accent,
                ),
              ),
              const Spacer(),
              Text(
                '${groups.length} 条 · $words 个词',
                style: TextStyle(fontSize: 11, color: t.sub),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '说到这些词，她就会想起对应的事 —— 内容不在这里展开。',
            style: TextStyle(fontSize: 11, color: t.sub, height: 1.4),
          ),
          const SizedBox(height: 10),
          if (groups.isEmpty)
            Text(
              '还没有关键词记忆：攒够片段、整理到「经历」一层时才会提炼。',
              style: TextStyle(fontSize: 12, color: t.sub, height: 1.45),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < groups.length; i++) ...[
                  if (i > 0) const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final k in groups[i]) _keywordChip(accent, k),
                    ],
                  ),
                ],
              ],
            ),
          if (audience.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '知情：${audience.join('、')}',
              style: TextStyle(fontSize: 10.5, color: t.sub),
            ),
          ],
        ],
      ),
    );
  }

  Widget _keywordChip(Color accent, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: accent,
        ),
      ),
    );
  }

  Widget _layerCard(
    ChatGalTheme t, {
    required String title,
    required String body,
    Color? titleColor,
    Color? tint,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tint ?? t.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: titleColor ?? t.ink,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(fontSize: 12, color: t.sub, height: 1.45),
          ),
        ],
      ),
    );
  }
}
