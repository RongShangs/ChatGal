import 'validation_error.dart';

/// Structured leave-settlement proposal (AI output).
///
/// 只保留 `deltas`：模型回传的 `events` / `evidence` 从来没有被读过，
/// 留着只会让「作者以为写了就生效」。
class SettlementProposal {
  const SettlementProposal({required this.deltas});

  /// Character stat id → integer delta.
  final Map<String, int> deltas;

  factory SettlementProposal.fromJson(Map<String, Object?> json) {
    final raw = json['deltas'];
    if (raw is! Map) {
      throw SettlementFormatException('deltas must be object');
    }
    final deltas = <String, int>{};
    raw.forEach((k, v) {
      // 容忍模型把整数写成 1.0（JSON double）：直接抛错会让整场离场被拒、
      // 数值一个都不结算 —— 那比"取整"危险得多。只拒真正的小数。
      if (v is int) {
        deltas['$k'] = v;
        return;
      }
      if (v is double && v == v.roundToDouble()) {
        deltas['$k'] = v.toInt();
        return;
      }
      throw SettlementFormatException('delta $k must be integer, got $v');
    });
    return SettlementProposal(deltas: deltas);
  }
}

class SettlementFormatException implements Exception {
  SettlementFormatException(this.message);
  final String message;

  @override
  String toString() => 'SettlementFormatException: $message';
}

/// Integer + whitelist + clamp for settlement deltas.
class SettlementValidator {
  const SettlementValidator();

  /// Returns clamped deltas or throws [SettlementValidationError].
  ///
  /// Levels:
  /// 1. non-integer already rejected in parse
  /// 2. key ∉ 本幕声明的受控变量 → error；key 未注册 → error
  /// 3. |d| > 该变量自己的 `maxAbsDelta` → clamp
  /// 4. final value clamp to [min, max] if provided (not forced 0..100)
  Map<String, int> apply({
    required SettlementProposal proposal,
    required Set<String> allowedVars,
    required Map<String, int> maxAbsDeltaPerVar,
    required Map<String, int> currentValues,
    Map<String, ({num? min, num? max})> ranges = const {},
  }) {
    for (final key in proposal.deltas.keys) {
      if (!allowedVars.contains(key)) {
        throw SettlementValidationError('var $key is not a settlement variable');
      }
      if (!currentValues.containsKey(key) && !ranges.containsKey(key)) {
        throw SettlementValidationError('var $key not registered');
      }
    }
    final out = <String, int>{};
    for (final e in proposal.deltas.entries) {
      var d = e.value;
      final cap = maxAbsDeltaPerVar[e.key] ?? 3;
      if (d.abs() > cap) {
        d = d.isNegative ? -cap : cap;
      }
      out[e.key] = d;
    }
    // Return deltas (not absolute); caller applies with range clamp.
    return out;
  }
}

class SettlementValidationError implements Exception {
  SettlementValidationError(this.message);
  final String message;

  @override
  String toString() => 'SettlementValidationError: $message';
}

ValidationReport settlementReportError(String message) {
  return ValidationReport(
    errors: [
      ValidationError(
        code: 'settlement_invalid',
        message: message,
        path: '/settlement',
      ),
    ],
    warnings: const [],
  );
}
