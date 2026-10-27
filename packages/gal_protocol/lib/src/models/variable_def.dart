import '../error_code.dart';
import '../validation_error.dart';
import 'manifest.dart';

/// Variable definition with type + bounds.
class VariableDef {
  const VariableDef({
    required this.id,
    required this.type,
    this.defaultValue,
    this.min,
    this.max,
    this.enumValues = const [],
    this.description,
    this.label,
  });

  static const typeBool = 'bool';
  static const typeInt = 'int';
  static const typeNumber = 'number';
  static const typeString = 'string';
  static const typeEnum = 'enum';

  static const Set<String> types = {
    typeBool,
    typeInt,
    typeNumber,
    typeString,
    typeEnum,
  };

  final String id;
  final String type;
  final Object? defaultValue;
  final num? min;
  final num? max;
  final List<String> enumValues;
  final String? description;

  /// Human-facing name for UI (e.g. 「好感」 next to 「戒戒好感」).
  final String? label;

  factory VariableDef.fromJson(Map<String, Object?> json, {String path = ''}) {
    final id = json['id'];
    final type = json['type'];
    if (id is! String || id.isEmpty) {
      throw PackageFormatException([
        ProtocolErrors.type(path, 'id', 'non-empty string', id),
      ]);
    }
    if (type is! String || !types.contains(type)) {
      throw PackageFormatException([
        ValidationError(
          code: ErrorCodes.invalidValue,
          message: 'Variable type must be one of ${types.join(', ')}',
          path: '$path/type',
          hint: 'value=$type',
        ),
      ]);
    }

    List<String> enums = const [];
    if (json['enum'] != null) {
      final e = json['enum'];
      if (e is! List) {
        throw PackageFormatException([
          ProtocolErrors.type(path, 'enum', 'array', e),
        ]);
      }
      enums = e.map((x) => x.toString()).toList();
    }

    return VariableDef(
      id: id,
      type: type,
      defaultValue: json['default'],
      min: json['min'] as num?,
      max: json['max'] as num?,
      enumValues: enums,
      description: json['description'] as String?,
      label: json['label'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type,
        if (defaultValue != null) 'default': defaultValue,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (enumValues.isNotEmpty) 'enum': enumValues,
        if (description != null) 'description': description,
        if (label != null) 'label': label,
      };

  ValidationError? validateValue(Object? value, {required String path}) {
    switch (type) {
      case typeBool:
        if (value is! bool) {
          return ProtocolErrors.type(path, id, 'bool', value);
        }
      case typeInt:
        if (value is! int) {
          return ProtocolErrors.type(path, id, 'int', value);
        }
        return _checkRange(value, path);
      case typeNumber:
        if (value is! num) {
          return ProtocolErrors.type(path, id, 'number', value);
        }
        return _checkRange(value, path);
      case typeString:
        if (value is! String) {
          return ProtocolErrors.type(path, id, 'string', value);
        }
      case typeEnum:
        if (value is! String || !enumValues.contains(value)) {
          return ValidationError(
            code: ErrorCodes.invalidValue,
            message: 'Value must be one of ${enumValues.join(', ')}',
            path: path,
            hint: 'value=$value',
          );
        }
    }
    return null;
  }

  ValidationError? _checkRange(num value, String path) {
    if (min != null && value < min!) {
      return ValidationError(
        code: ErrorCodes.invalidValue,
        message: 'Value $value < min $min',
        path: path,
      );
    }
    if (max != null && value > max!) {
      return ValidationError(
        code: ErrorCodes.invalidValue,
        message: 'Value $value > max $max',
        path: path,
      );
    }
    return null;
  }
}
