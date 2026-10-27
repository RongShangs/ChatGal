import 'package:gal_protocol/gal_protocol.dart';

class InstallResult {
  const InstallResult.success({
    required this.packageRef,
    required this.installDir,
    required this.contentHash,
  }) : error = null;

  const InstallResult.failure({
    required this.error,
    this.packageRef,
    this.installDir,
    this.contentHash,
  });

  final ValidationError? error;
  final PackageRef? packageRef;
  final String? installDir;
  final String? contentHash;

  bool get ok => error == null;
}

class ExportResult {
  const ExportResult.success({required this.file, required this.packageRef})
      : error = null;

  const ExportResult.failure({
    required this.error,
    this.file,
    this.packageRef,
  });

  final ValidationError? error;
  final String? file;
  final PackageRef? packageRef;

  bool get ok => error == null;
}
