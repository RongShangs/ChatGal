/// Immutable package identity used by saves and install records.
class PackageRef {
  const PackageRef({
    required this.packageId,
    required this.version,
    required this.contentHash,
    this.displayName,
    this.coverAssetId,
  });

  final String packageId;
  final String version;
  final String contentHash;
  final String? displayName;
  final String? coverAssetId;

  Map<String, Object?> toJson() => {
        'packageId': packageId,
        'version': version,
        'contentHash': contentHash,
        if (displayName != null) 'displayName': displayName,
        if (coverAssetId != null) 'coverAssetId': coverAssetId,
      };

  factory PackageRef.fromJson(Map<String, Object?> json) {
    return PackageRef(
      packageId: json['packageId']! as String,
      version: json['version']! as String,
      contentHash: json['contentHash']! as String,
      displayName: json['displayName'] as String?,
      coverAssetId: json['coverAssetId'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PackageRef &&
      other.packageId == packageId &&
      other.version == version &&
      other.contentHash == contentHash;

  @override
  int get hashCode => Object.hash(packageId, version, contentHash);

  @override
  String toString() =>
      'PackageRef($packageId@$version#${contentHash.substring(0, 8)}…)';
}
