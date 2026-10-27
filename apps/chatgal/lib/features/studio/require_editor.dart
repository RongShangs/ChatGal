import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import 'hints.dart';

/// 出口条件的一行：「变量 比较符 值」。
///
/// 它是「简单模式」的数据形状；序列化后仍然是**中缀文本**（引擎只认文本），
/// 所以简单模式与高级模式共用同一个 `require` 字符串。
class RequireRow {
  RequireRow({this.variable = '', this.op = '>', this.rhs = ''});

  String variable;

  /// `>` `<` `>=` `<=` `==` `!=`
  String op;

  /// 右边：数字（如 `7`）或带引号的变量（如 `"戒戒信任"`）。
  String rhs;

  bool get isComplete =>
      variable.trim().isNotEmpty && rhs.trim().isNotEmpty;

  RequireRow copy() => RequireRow(variable: variable, op: op, rhs: rhs);
}

/// 简单模式的整条条件：若干行 + 统一的连接符。
class RequireDraft {
  const RequireDraft({required this.rows, this.joiner = '&'});

  final List<RequireRow> rows;

  /// `&`（并且）或 `|`（或者）。简单模式只做同一种连接。
  final String joiner;
}

const kRequireOps = ['>', '>=', '<', '<=', '==', '!='];

const _opPattern = '>=|<=|==|!=|>|<';

/// 文本 → 条件行。**解析不了就返回 null**（交给高级模式），解析器不猜：
/// 含括号、算术、`!`、或混用 `&` 与 `|` 的表达式都属于「复杂条件」。
RequireDraft? parseRequireDraft(String text) {
  final t = text.trim();
  if (t.isEmpty) return const RequireDraft(rows: []);
  if (t.contains('(') || t.contains(')')) return null;
  if (t.contains('+') || t.contains('*') || t.contains('/')) return null;
  // 注意：`!` 不能在这里一律拒绝 —— `!=` 里也含 `!`。取反（`!"a" > 1`）由下面
  // 每行的正则兜住：那些行不以 `"变量名"` 开头，匹配不上就老实地转投高级模式。

  // 顶层切分：按 & / | 拆，引号里的不算。
  final parts = <String>[];
  final separators = <String>[];
  var buf = StringBuffer();
  var inQuote = false;
  var quoteChar = '';
  for (var i = 0; i < t.length; i++) {
    final c = t[i];
    if (inQuote) {
      buf.write(c);
      if (c == quoteChar) inQuote = false;
      continue;
    }
    if (c == '"' || c == "'") {
      inQuote = true;
      quoteChar = c;
      buf.write(c);
      continue;
    }
    if (c == '&' || c == '|') {
      parts.add(buf.toString());
      buf = StringBuffer();
      separators.add(c);
      // 允许 `&&` / `||`
      if (i + 1 < t.length && t[i + 1] == c) i++;
      continue;
    }
    buf.write(c);
  }
  parts.add(buf.toString());

  final distinct = separators.toSet();
  if (distinct.length > 1) return null; // 混用 & 与 |
  final joiner = distinct.isEmpty ? '&' : distinct.first;

  final re = RegExp('^"([^"]+)"\\s*($_opPattern)\\s*(.+)\$');
  final rows = <RequireRow>[];
  for (final raw in parts) {
    final part = raw.trim();
    if (part.isEmpty) return null;
    final m = re.firstMatch(part);
    if (m == null) return null;
    final rhs = m.group(3)!.trim();
    // 右边要么是数字（可带负号/小数），要么是带引号的变量名。
    final isNumber = RegExp(r'^-?\d+(\.\d+)?$').hasMatch(rhs);
    final isVariable = RegExp('^"[^"]+"\$').hasMatch(rhs);
    if (!isNumber && !isVariable) return null;
    rows.add(RequireRow(variable: m.group(1)!, op: m.group(2)!, rhs: rhs));
  }
  return RequireDraft(rows: rows, joiner: joiner);
}

/// 条件行 → 文本（未填完的行会被跳过；一行都没有则返回空串＝无条件成立）。
String buildRequireText({
  required List<RequireRow> rows,
  required String joiner,
}) {
  final parts = <String>[
    for (final r in rows)
      if (r.isComplete) '"${r.variable.trim()}" ${r.op} ${r.rhs.trim()}',
  ];
  return parts.join(' $joiner ');
}

/// 出口条件的编辑器：**简单模式**（一行行下拉选）+ **高级模式**（直接写表达式）。
///
/// [controller] 始终是唯一真相：简单模式改动后会立刻把生成的文本写回去，
/// 保存/写盘读的都是这个 controller。
class RequireEditor extends StatefulWidget {
  const RequireEditor({
    super.key,
    required this.theme,
    required this.controller,
    required this.knownVariables,
    required this.onChanged,
    this.errorText,
  });

  final ChatGalTheme theme;
  final TextEditingController controller;

  /// 已注册的变量 id（下拉选项 + 未注册提示）。
  final Set<String> knownVariables;
  final VoidCallback onChanged;

  /// 由父级算好的校验错误（语法 / 未注册变量）。
  final String? errorText;

  @override
  State<RequireEditor> createState() => _RequireEditorState();
}

class _RequireEditorState extends State<RequireEditor> {
  late List<RequireRow> _rows;
  late String _joiner;
  late bool _advanced;

  @override
  void initState() {
    super.initState();
    _loadFromText();
  }

  void _loadFromText() {
    final draft = parseRequireDraft(widget.controller.text);
    if (draft == null) {
      _advanced = true;
      _rows = [];
      _joiner = '&';
      return;
    }
    _advanced = false;
    _rows = draft.rows.map((r) => r.copy()).toList();
    _joiner = draft.joiner;
  }

  void _pushText() {
    final text = buildRequireText(rows: _rows, joiner: _joiner);
    if (widget.controller.text != text) {
      widget.controller.text = text;
    }
    widget.onChanged();
  }

  void _setAdvanced(bool value) {
    if (value == _advanced) return;
    if (!value) {
      // 高级 → 简单：解析不了就拒绝切换，并说明原因（不静默丢条件）。
      final draft = parseRequireDraft(widget.controller.text);
      if (draft == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '这条条件用了括号 / 加减 / 且与或混用，简单模式表达不了 —— 继续用高级模式编辑即可。',
            ),
          ),
        );
        return;
      }
      setState(() {
        _advanced = false;
        _rows = draft.rows.map((r) => r.copy()).toList();
        _joiner = draft.joiner;
      });
      return;
    }
    setState(() => _advanced = true);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _modeChip('条件行', !_advanced, () => _setAdvanced(false)),
            const SizedBox(width: 6),
            _modeChip('表达式', _advanced, () => _setAdvanced(true)),
            const Spacer(),
            Text(
              _advanced ? '给熟手：直接写中缀表达式' : '每行一个判断，适合不写代码的人',
              style: TextStyle(fontSize: 10.5, color: t.sub),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_advanced) _advancedField(t) else _simpleRows(t),
        if (widget.errorText != null) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, size: 14, color: Colors.red.shade400),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  widget.errorText!,
                  style: TextStyle(fontSize: 11.5, color: Colors.red.shade400),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 6),
        Text(
          widget.controller.text.trim().isEmpty
              ? '当前：无条件 —— 轮到这一块就必定触发'
              : '当前：${widget.controller.text.trim()}',
          style: TextStyle(
            fontSize: 11,
            height: 1.5,
            color: widget.controller.text.trim().isEmpty ? t.accent : t.ink,
          ),
        ),
      ],
    );
  }

  Widget _modeChip(String label, bool on, VoidCallback onTap) {
    final t = widget.theme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: on ? t.accent.withValues(alpha: 0.16) : t.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: on ? t.accent : t.sub.withValues(alpha: 0.25),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: on ? FontWeight.w700 : FontWeight.w400,
            color: on ? t.accent : t.sub,
          ),
        ),
      ),
    );
  }

  Widget _advancedField(ChatGalTheme t) {
    return TextField(
      controller: widget.controller,
      maxLines: 3,
      minLines: 2,
      onChanged: (_) => widget.onChanged(),
      style: TextStyle(fontSize: 12.5, color: t.ink, height: 1.5),
      decoration: InputDecoration(
        isDense: true,
        hintText: '例："day" > 7 & "戒戒好感" > 80',
        hintStyle: TextStyle(fontSize: 12.5, color: t.sub),
        filled: true,
        fillColor: t.card,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: t.sub.withValues(alpha: 0.25)),
        ),
      ),
    );
  }

  Widget _simpleRows(ChatGalTheme t) {
    final vars = widget.knownVariables.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_rows.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '这些条件之间（$_joiner == 的判断方式）',
                  style: TextStyle(fontSize: 11.5, color: t.sub),
                ),
                const SizedBox(height: 5),
                // 用 Wrap + 短标签：早先「全部满足（并且）／满足任一（或者）」
                // 两个长胶囊排在一行，窄屏上直接顶出容器。
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _modeChip('并且', _joiner == '&', () {
                      setState(() => _joiner = '&');
                      _pushText();
                    }),
                    _modeChip('或者', _joiner == '|', () {
                      setState(() => _joiner = '|');
                      _pushText();
                    }),
                    Text(
                      _joiner == '&' ? '每个条件都要成立' : '任一条成立即可',
                      style: TextStyle(fontSize: 11, color: t.sub),
                    ),
                  ],
                ),
              ],
            ),
          ),
        for (var i = 0; i < _rows.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 4,
                  child: _variableDropdown(t, vars, i),
                ),
                const SizedBox(width: 6),
                Expanded(flex: 3, child: _opDropdown(t, i)),
                const SizedBox(width: 6),
                Expanded(flex: 4, child: _rhsField(t, i)),
                _rowIcon(t, Icons.close_rounded, '删掉这一行', () {
                  setState(() => _rows.removeAt(i));
                  _pushText();
                }),
              ],
            ),
          ),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _rows.add(RequireRow(
                    variable: vars.isEmpty ? '' : vars.first,
                    rhs: '',
                  ));
                });
                _pushText();
              },
              icon: Icon(Icons.add_rounded, size: 16, color: t.accent),
              label: Text(
                '添加条件',
                style: TextStyle(fontSize: 12, color: t.accent),
              ),
            ),
            const SizedBox(width: 8),
            if (_rows.isNotEmpty)
              Text(
                '还没填值的那一行不会写进条件',
                style: TextStyle(fontSize: 10.5, color: t.sub),
              ),
          ],
        ),
        if (vars.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '这个包还没有注册任何变量 —— 先去「基础信息」注册（例如 day），条件才有东西可比。',
              style: TextStyle(fontSize: 11, color: t.accent),
            ),
          ),
      ],
    );
  }

  Widget _variableDropdown(ChatGalTheme t, List<String> vars, int i) {
    final row = _rows[i];
    return StudioDropdown<String>(
      theme: t,
      dense: true,
      value: row.variable.isEmpty ? null : row.variable,
      placeholder: '变量',
      options: <(String, String)>[
        for (final v in vars) (v, v),
        // 文本里写了但没注册的变量也要能显示出来，否则一进简单模式就“丢”了
        if (row.variable.isNotEmpty && !vars.contains(row.variable))
          (row.variable, '${row.variable}（未注册）'),
      ],
      onChanged: (v) {
        setState(() => _rows[i].variable = v ?? '');
        _pushText();
      },
    );
  }

  Widget _opDropdown(ChatGalTheme t, int i) {
    final op = kRequireOps.contains(_rows[i].op) ? _rows[i].op : '>';
    return StudioDropdown<String>(
      theme: t,
      dense: true,
      value: op,
      options: <(String, String)>[for (final o in kRequireOps) (o, o)],
      onChanged: (v) {
        setState(() => _rows[i].op = v ?? '>');
        _pushText();
      },
    );
  }

  Widget _rhsField(ChatGalTheme t, int i) {
    return TextField(
      controller: TextEditingController(text: _rows[i].rhs),
      key: ValueKey('require_rhs_$i${_rows[i].variable}'),
      style: TextStyle(fontSize: 12, color: t.ink),
      onChanged: (v) {
        _rows[i].rhs = v;
        _pushText();
      },
      decoration: _decoration(t, '7 或 "变量"'),
    );
  }

  Widget _rowIcon(
    ChatGalTheme t,
    IconData icon,
    String tip,
    VoidCallback onTap,
  ) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: t.sub),
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    );
  }

  InputDecoration _decoration(ChatGalTheme t, String hint) {
    return InputDecoration(
      isDense: true,
      hintText: hint,
      // 与全局一致：提示明显更浅（这一处自己写了样式，会盖住主题）
      hintStyle: TextStyle(fontSize: 11.5, color: t.sub.withValues(alpha: 0.55)),
      filled: true,
      fillColor: t.card,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.sub.withValues(alpha: 0.25)),
      ),
    );
  }
}
