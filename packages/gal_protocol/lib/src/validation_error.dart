import 'error_code.dart';

/// Path-located validation error.
///
/// [path] is a JSON-pointer-like path, e.g. `/stories/main/nodes/day1_1`.
class ValidationError {
  const ValidationError({
    required this.code,
    required this.message,
    required this.path,
    this.hint,
  });

  final String code;
  final String message;
  final String path;
  final String? hint;

  Map<String, Object?> toJson() => {
        'code': code,
        'message': message,
        'path': path,
        if (hint != null) 'hint': hint,
      };

  @override
  String toString() => '[$code] $path: $message'
      '${hint == null ? '' : ' ($hint)'}';

  @override
  bool operator ==(Object other) =>
      other is ValidationError &&
      other.code == code &&
      other.message == message &&
      other.path == path;

  @override
  int get hashCode => Object.hash(code, message, path);
}

/// Aggregate validation result.
class ValidationReport {
  const ValidationReport({required this.errors, this.warnings = const []});

  final List<ValidationError> errors;
  final List<ValidationError> warnings;

  bool get isValid => errors.isEmpty;

  factory ValidationReport.ok() =>
      const ValidationReport(errors: [], warnings: []);

  Map<String, Object?> toJson() => {
        'isValid': isValid,
        'errors': errors.map((e) => e.toJson()).toList(),
        'warnings': warnings.map((e) => e.toJson()).toList(),
      };

  @override
  String toString() {
    if (isValid && warnings.isEmpty) return 'ValidationReport.ok';
    final buf = StringBuffer()
      ..writeln(isValid ? 'VALID (with warnings)' : 'INVALID');
    for (final e in errors) {
      buf.writeln('  ERROR $e');
    }
    for (final w in warnings) {
      buf.writeln('  WARN  $w');
    }
    return buf.toString();
  }
}

/// Helpers used by validators.
abstract final class ProtocolErrors {
  static ValidationError missing(String path, String field) => ValidationError(
        code: ErrorCodes.missingField,
        message: 'Required field "$field" is missing',
        path: path,
      );

  static ValidationError type(
    String path,
    String field,
    String expected,
    Object? actual,
  ) =>
      ValidationError(
        code: ErrorCodes.invalidType,
        message:
            'Field "$field" expected $expected, got ${actual.runtimeType}',
        path: path,
        hint: 'value=$actual',
      );

  static ValidationError ref(
    String path,
    String code,
    String message, {
    String? hint,
  }) =>
      ValidationError(code: code, message: message, path: path, hint: hint);
}
