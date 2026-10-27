import 'package:flutter/material.dart';

/// Collapse blank lines so dialogue stays continuous.
/// Keeps a single `\n` only between distinct paragraphs; no empty lines.
String cleanChatText(String text) {
  var s = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // remove HTML-ish leftovers if any
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'</?b>', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'</?big>', caseSensitive: false), '');
  // split on any run of newlines, drop empty segments, join with \n
  final parts = s
      .split(RegExp(r'\n+'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  return parts.join('\n');
}

/// Build TextSpans with parentheses/actions in gray for streaming-safe paint.
/// Opening ( or （ starts gray; closing ) or ） ends gray. Unclosed open paren
/// stays gray through the end of current partial text.
TextSpan buildActionTextSpan(
  String text, {
  required Color ink,
  required Color actionColor,
  TextStyle? style,
}) {
  final base = (style ?? const TextStyle()).copyWith(color: ink);
  final actionStyle = base.copyWith(color: actionColor);
  final spans = <TextSpan>[];
  final buffer = StringBuffer();
  var inAction = false;

  void flush() {
    if (buffer.isEmpty) return;
    spans.add(TextSpan(
      text: buffer.toString(),
      style: inAction ? actionStyle : base,
    ));
    buffer.clear();
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch == '(' || ch == '（') {
      flush();
      inAction = true;
      buffer.write(ch);
    } else if (ch == ')' || ch == '）') {
      buffer.write(ch);
      flush();
      inAction = false;
    } else {
      buffer.write(ch);
    }
  }
  flush();
  if (spans.isEmpty) {
    return TextSpan(text: text, style: base);
  }
  return TextSpan(children: spans);
}

/// Convenience widget.
class ActionText extends StatelessWidget {
  const ActionText(
    this.text, {
    super.key,
    required this.ink,
    required this.actionColor,
    this.style,
    this.textAlign,
  });

  final String text;
  final Color ink;
  final Color actionColor;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      buildActionTextSpan(
        text,
        ink: ink,
        actionColor: actionColor,
        style: style,
      ),
      textAlign: textAlign,
    );
  }
}
