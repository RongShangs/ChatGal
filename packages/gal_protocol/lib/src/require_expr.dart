import 'world_snapshot.dart';

/// 出口条件 `require` 的**中缀文本**解析与求值。
///
/// 作者写法（与校验器共用同一个解析器，装载期就能报语法错）：
///
/// ```jsonc
/// "require": "\"day\" == 14 & \"戒戒好感\" + \"戒戒信任\" < 120"
/// ```
///
/// * 变量名用双引号包起来（`"day"`、`"戒戒好感"`）；数字直接写。
/// * 比较：`>` `<` `>=` `<=` `==` `!=`
/// * 逻辑：`&`（与，也接受 `&&`）、`|`（或，也接受 `||`）、`!`（非）
/// * 算术：`+` `-`（例如「好感 + 信任」），可用括号分组
/// * 没写 `require` 的出口块 = 无条件成立
///
/// 未注册的变量名由包校验器在装载期拦下；运行期取不到值一律当 0/空串，
/// **绝不抛异常**（条件来自内容包，坏条件不能把离场事务炸掉）。
class RequireExpr {
  const RequireExpr(this.root);

  final _BoolNode root;

  bool evaluate(WorldSnapshot world) => root.eval(world);

  /// 语法错误时抛 [RequireSyntaxException]。
  static RequireExpr parse(String text) {
    final parser = _Parser(_tokenize(text));
    final node = parser.parse();
    return RequireExpr(node);
  }

  /// 方便校验器：能解析就返回 null，否则返回人话错误。
  static String? check(String text) {
    try {
      parse(text);
      return null;
    } on RequireSyntaxException catch (e) {
      return e.message;
    }
  }

  /// 文本里引用到的变量名（校验器用来查「是否注册过」）。
  static List<String> variablesIn(String text) {
    return _tokenize(text)
        .where((t) => t.kind == _TokenKind.ident)
        .map((t) => t.text)
        .toList();
  }
}

class RequireSyntaxException implements Exception {
  RequireSyntaxException(this.message);
  final String message;

  @override
  String toString() => 'RequireSyntaxException($message)';
}

// ---------------------------------------------------------------- 词法

enum _TokenKind { ident, number, op, lparen, rparen, and, or, not, end }

class _Token {
  const _Token(this.kind, this.text, this.pos);
  final _TokenKind kind;
  final String text;
  final int pos;
}

List<_Token> _tokenize(String src) {
  final out = <_Token>[];
  var i = 0;
  while (i < src.length) {
    final ch = src[i];
    if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
      i++;
      continue;
    }
    if (ch == '"' || ch == "'") {
      final quote = ch;
      final start = i;
      i++;
      final buf = StringBuffer();
      var closed = false;
      while (i < src.length) {
        if (src[i] == '\\' && i + 1 < src.length) {
          buf.write(src[i + 1]);
          i += 2;
          continue;
        }
        if (src[i] == quote) {
          closed = true;
          i++;
          break;
        }
        buf.write(src[i]);
        i++;
      }
      if (!closed) {
        throw RequireSyntaxException('第 $start 个字符的引号没有闭合：$src');
      }
      out.add(_Token(_TokenKind.ident, buf.toString(), start));
      continue;
    }
    if (RegExp(r'[0-9]').hasMatch(ch)) {
      final start = i;
      while (i < src.length && RegExp(r'[0-9.]').hasMatch(src[i])) {
        i++;
      }
      out.add(_Token(_TokenKind.number, src.substring(start, i), start));
      continue;
    }
    if (ch == '&') {
      i += (i + 1 < src.length && src[i + 1] == '&') ? 2 : 1;
      out.add(_Token(_TokenKind.and, '&', i));
      continue;
    }
    if (ch == '|') {
      i += (i + 1 < src.length && src[i + 1] == '|') ? 2 : 1;
      out.add(_Token(_TokenKind.or, '|', i));
      continue;
    }
    if (ch == '!') {
      if (i + 1 < src.length && src[i + 1] == '=') {
        out.add(_Token(_TokenKind.op, '!=', i));
        i += 2;
        continue;
      }
      i++;
      out.add(_Token(_TokenKind.not, '!', i));
      continue;
    }
    if (ch == '=') {
      if (i + 1 < src.length && src[i + 1] == '=') {
        out.add(_Token(_TokenKind.op, '==', i));
        i += 2;
        continue;
      }
      throw RequireSyntaxException('第 $i 个字符：比较相等要写 "=="，单个 "=" 不认');
    }
    if (ch == '>' || ch == '<') {
      if (i + 1 < src.length && src[i + 1] == '=') {
        out.add(_Token(_TokenKind.op, '$ch=', i));
        i += 2;
        continue;
      }
      out.add(_Token(_TokenKind.op, ch, i));
      i++;
      continue;
    }
    if (ch == '+' || ch == '-') {
      out.add(_Token(_TokenKind.op, ch, i));
      i++;
      continue;
    }
    if (ch == '(') {
      out.add(_Token(_TokenKind.lparen, ch, i));
      i++;
      continue;
    }
    if (ch == ')') {
      out.add(_Token(_TokenKind.rparen, ch, i));
      i++;
      continue;
    }
    throw RequireSyntaxException('第 $i 个字符出现了不认识的符号 "$ch"');
  }
  out.add(_Token(_TokenKind.end, '', src.length));
  return out;
}

// ---------------------------------------------------------------- 语法树

abstract class _BoolNode {
  bool eval(WorldSnapshot world);
}

class _NumNode {
  const _NumNode(this.terms);

  /// 每项带符号：`a + b - c` → [(+1,a), (-1,c)]
  final List<(int, _Operand)> terms;

  num value(WorldSnapshot world) {
    num sum = 0;
    for (final (sign, op) in terms) {
      sum += sign * op.value(world);
    }
    return sum;
  }

  /// 纯变量/字面量且非算术时，能不能拿到原始值（字符串比较要用）。
  Object? raw(WorldSnapshot world) {
    if (terms.length == 1 && terms.first.$1 == 1) {
      return terms.first.$2.raw(world);
    }
    return null;
  }
}

class _Operand {
  const _Operand({this.literal, this.variable, this.group});

  final num? literal;
  final String? variable;
  final _NumNode? group;

  num value(WorldSnapshot world) {
    if (literal != null) return literal!;
    if (group != null) return group!.value(world);
    final v = world.variables[variable];
    if (v is num) return v;
    return num.tryParse('$v') ?? 0;
  }

  Object? raw(WorldSnapshot world) {
    if (literal != null) return literal;
    if (group != null) return group!.raw(world);
    return world.variables[variable];
  }
}

class _Compare implements _BoolNode {
  const _Compare(this.left, this.op, this.right);
  final _NumNode left;
  final String op;
  final _NumNode right;

  @override
  bool eval(WorldSnapshot world) {
    final lr = left.raw(world);
    final rr = right.raw(world);
    // 两边都不是数字时，只支持 == / != 的字符串比较。
    final lNum = lr is num;
    final rNum = rr is num;
    if (!lNum || !rNum) {
      final ls = '$lr';
      final rs = '$rr';
      if (!lNum && !rNum) {
        switch (op) {
          case '==':
            return ls == rs;
          case '!=':
            return ls != rs;
          default:
            return false;
        }
      }
    }
    final l = left.value(world);
    final r = right.value(world);
    switch (op) {
      case '>':
        return l > r;
      case '>=':
        return l >= r;
      case '<':
        return l < r;
      case '<=':
        return l <= r;
      case '==':
        return l == r;
      case '!=':
        return l != r;
    }
    return false;
  }
}

class _And implements _BoolNode {
  const _And(this.parts);
  final List<_BoolNode> parts;

  @override
  bool eval(WorldSnapshot world) {
    for (final p in parts) {
      if (!p.eval(world)) return false;
    }
    return true;
  }
}

class _Or implements _BoolNode {
  const _Or(this.parts);
  final List<_BoolNode> parts;

  @override
  bool eval(WorldSnapshot world) {
    for (final p in parts) {
      if (p.eval(world)) return true;
    }
    return false;
  }
}

class _Not implements _BoolNode {
  const _Not(this.child);
  final _BoolNode child;

  @override
  bool eval(WorldSnapshot world) => !child.eval(world);
}

class _AlwaysTrue implements _BoolNode {
  const _AlwaysTrue();

  @override
  bool eval(WorldSnapshot world) => true;
}

// ---------------------------------------------------------------- 递归下降

class _Parser {
  _Parser(this.tokens);
  final List<_Token> tokens;
  int _i = 0;

  _Token get _cur => tokens[_i];

  _BoolNode parse() {
    if (_cur.kind == _TokenKind.end) return const _AlwaysTrue();
    final node = _or();
    if (_cur.kind != _TokenKind.end) {
      throw RequireSyntaxException('第 ${_cur.pos} 个字符附近有多余内容 "${_cur.text}"');
    }
    return node;
  }

  _BoolNode _or() {
    final parts = <_BoolNode>[_and()];
    while (_cur.kind == _TokenKind.or) {
      _i++;
      parts.add(_and());
    }
    return parts.length == 1 ? parts.first : _Or(parts);
  }

  _BoolNode _and() {
    final parts = <_BoolNode>[_unary()];
    while (_cur.kind == _TokenKind.and) {
      _i++;
      parts.add(_unary());
    }
    return parts.length == 1 ? parts.first : _And(parts);
  }

  _BoolNode _unary() {
    if (_cur.kind == _TokenKind.not) {
      _i++;
      return _Not(_unary());
    }
    return _primary();
  }

  _BoolNode _primary() {
    final start = _i;
    if (_cur.kind == _TokenKind.lparen) {
      // 括号既可能是布尔分组 `(a > 1) & (b > 2)`，也可能是算术操作数
      // `("好感" + "信任") < 120`。按布尔分组试一次，不行就回溯当算术读 ——
      // 不这样做，作者给和式加个括号就会在装载期报语法错。
      _i++;
      try {
        final inner = _or();
        _expect(_TokenKind.rparen, ')');
        return inner;
      } on RequireSyntaxException {
        _i = start;
      }
    }
    final left = _num();
    if (_cur.kind != _TokenKind.op || !_isCompare(_cur.text)) {
      throw RequireSyntaxException(
        '第 ${_cur.pos} 个字符附近缺少比较运算符（> < >= <= == !=）',
      );
    }
    final op = _cur.text;
    _i++;
    final right = _num();
    return _Compare(left, op, right);
  }

  bool _isCompare(String op) =>
      op == '>' || op == '<' || op == '>=' || op == '<=' || op == '==' || op == '!=';

  _NumNode _num() {
    final terms = <(int, _Operand)>[];
    var sign = 1;
    if (_cur.kind == _TokenKind.op && (_cur.text == '-' || _cur.text == '+')) {
      sign = _cur.text == '-' ? -1 : 1;
      _i++;
    }
    terms.add((sign, _operand()));
    while (_cur.kind == _TokenKind.op &&
        (_cur.text == '+' || _cur.text == '-')) {
      final s = _cur.text == '-' ? -1 : 1;
      _i++;
      terms.add((s, _operand()));
    }
    return _NumNode(terms);
  }

  _Operand _operand() {
    if (_cur.kind == _TokenKind.number) {
      final v = num.tryParse(_cur.text);
      if (v == null) {
        throw RequireSyntaxException('第 ${_cur.pos} 个字符：数字 "${_cur.text}" 不合法');
      }
      _i++;
      return _Operand(literal: v);
    }
    if (_cur.kind == _TokenKind.ident) {
      final name = _cur.text;
      _i++;
      return _Operand(variable: name);
    }
    if (_cur.kind == _TokenKind.lparen) {
      _i++;
      final inner = _num();
      _expect(_TokenKind.rparen, ')');
      return _Operand(group: inner);
    }
    throw RequireSyntaxException(
      '第 ${_cur.pos} 个字符附近需要一个变量名（带双引号）或数字',
    );
  }

  void _expect(_TokenKind kind, String what) {
    if (_cur.kind != kind) {
      throw RequireSyntaxException('第 ${_cur.pos} 个字符附近缺少 "$what"');
    }
    _i++;
  }
}
