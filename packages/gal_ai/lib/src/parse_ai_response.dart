import 'dart:convert';

import 'package:gal_protocol/gal_protocol.dart';

/// Parse model text into [AIResponse].
ParseOutcome parseAiResponse(String text) {
  final cleaned = text.trim();
  Object? decoded;

  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(cleaned);
  if (fence != null) {
    decoded = _tryDecode(fence.group(1)!.trim());
  }
  decoded ??= _tryDecode(cleaned);
  decoded ??= _tryDecode(extractJsonObject(cleaned));

  if (decoded is! Map) {
    // 非 JSON（模型直接回了台词）。保留原文当对白，但**不编表情**：
    // expressionId 留空表示「这一段没有给出任何表情信息」，调用方据此走
    // 「格式降级」处理，而不是把一个永远匹配不上的词当成合法答案。
    final plain = AIResponse(
      protocolVersion: 1,
      segments: [
        DialogueSegment(
          id: 's1',
          speakerId: 'jj',
          expressionId: '',
          text: cleaned.isEmpty ? '……' : cleaned,
        ),
      ],
    );
    return ParseOutcome.plainText(plain, cleaned);
  }

  final map = Map<String, Object?>.from(decoded);
  if (!map.containsKey('segments') && map.containsKey('text')) {
    // 扁平写法 `{text, expressionId, portraitId}`：**立绘字段一个都不能丢**。
    // 以前这里只搬了 text/expressionId，模型给对的 portraitId 被静默丢掉，
    // 下游就报「模型未给出可用立绘」——看起来像模型的错，其实是解析器丢的。
    map['segments'] = [
      {
        'id': 's1',
        'speakerId': map['speakerId'] ?? 'jj',
        'expressionId': map['expressionId'] ?? '',
        if (map['portraitId'] != null) 'portraitId': map['portraitId'],
        if (map['portrait'] != null) 'portrait': map['portrait'],
        'text': map['text'],
      }
    ];
  }
  map.putIfAbsent('protocolVersion', () => 1);

  try {
    final res = AIResponse.fromJson(map);
    if (res.segments.isEmpty) {
      return ParseOutcome.invalid('empty segments', cleaned);
    }
    return ParseOutcome.parsed(res, cleaned);
  } catch (e) {
    return ParseOutcome.invalid('$e', cleaned);
  }
}

Object? _tryDecode(String? s) {
  if (s == null || s.isEmpty) return null;
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}

String extractJsonObject(String input) {
  final start = input.indexOf('{');
  if (start < 0) return '';
  var depth = 0;
  var inStr = false;
  var esc = false;
  for (var i = start; i < input.length; i++) {
    final c = input[i];
    if (inStr) {
      if (esc) {
        esc = false;
      } else if (c == r'\') {
        esc = true;
      } else if (c == '"') {
        inStr = false;
      }
      continue;
    }
    if (c == '"') {
      inStr = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return input.substring(start, i + 1);
    }
  }
  return '';
}

class ParseOutcome {
  const ParseOutcome.parsed(this.response, this.raw)
      : kind = ParseKind.parsed,
        error = null;

  const ParseOutcome.plainText(this.response, this.raw)
      : kind = ParseKind.plainText,
        error = null;

  const ParseOutcome.invalid(this.error, this.raw)
      : kind = ParseKind.invalid,
        response = null;

  final ParseKind kind;
  final AIResponse? response;
  final String? error;
  final String raw;

  bool get ok => kind != ParseKind.invalid && response != null;
}

enum ParseKind { parsed, plainText, invalid }
