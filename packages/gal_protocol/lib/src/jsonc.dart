import 'dart:convert';

/// 内容包里的 JSON 允许写注释（作者要在文件里说明每个字段是干什么的），
/// 所以装载前先把 `//`、`/* */` 注释与尾逗号剥掉，再交给 [jsonDecode]。
///
/// 只做「剥离」，不改写任何数据：字符串字面量里的 `//`（例如 URL）与
/// 转义引号都不会被误伤。
String stripJsonComments(String src) {
  final withoutBom = src.startsWith('\uFEFF') ? src.substring(1) : src;
  final out = StringBuffer();
  var i = 0;
  final n = withoutBom.length;
  var inString = false;
  var escaped = false;

  while (i < n) {
    final ch = withoutBom[i];
    if (inString) {
      out.write(ch);
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      i++;
      continue;
    }
    if (ch == '"') {
      inString = true;
      out.write(ch);
      i++;
      continue;
    }
    if (ch == '/' && i + 1 < n) {
      final next = withoutBom[i + 1];
      if (next == '/') {
        i += 2;
        while (i < n && withoutBom[i] != '\n') {
          i++;
        }
        continue;
      }
      if (next == '*') {
        i += 2;
        while (i + 1 < n &&
            !(withoutBom[i] == '*' && withoutBom[i + 1] == '/')) {
          i++;
        }
        i = i + 2 <= n ? i + 2 : n;
        continue;
      }
    }
    out.write(ch);
    i++;
  }

  return _stripTrailingCommas(out.toString());
}

/// 删掉 `,` 后面只有空白、紧接着 `}` 或 `]` 的那种尾逗号（作者手写时常见）。
String _stripTrailingCommas(String src) {
  final out = StringBuffer();
  var inString = false;
  var escaped = false;
  for (var i = 0; i < src.length; i++) {
    final ch = src[i];
    if (inString) {
      out.write(ch);
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
      out.write(ch);
      continue;
    }
    if (ch == ',') {
      var j = i + 1;
      while (j < src.length &&
          (src[j] == ' ' ||
              src[j] == '\t' ||
              src[j] == '\n' ||
              src[j] == '\r')) {
        j++;
      }
      if (j < src.length && (src[j] == '}' || src[j] == ']')) continue;
    }
    out.write(ch);
  }
  return out.toString();
}

/// 剥注释 + 解析。解析失败照旧抛 [FormatException]（调用方决定怎么报错）。
Object? decodeJsonc(String src) => jsonDecode(stripJsonComments(src));
