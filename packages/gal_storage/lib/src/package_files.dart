/// 「哪些文件算包内容」的唯一判据（读树 / 拷贝 / 导出打 zip / 工程量文件四处共用）。
///
/// 以前每处各写各的过滤条件，于是漏了：编辑器原子写的临时文件
/// （早先是 `manifest.json.tmp`，**不带点前缀**）会被打进导出包、也会跟着
/// 拷贝进安装目录；而 [PackageInstaller] 的 `_copyTree` 那一处干脆**没有过滤**，
/// 连 `.content_hash` 都能被复制进创作台工程。
///
/// 这里只排除**存储层残留物**，不改内容包的文件名约定：
/// * 相对路径为空、或任何一段以 `.` 开头 → 不算（`.content_hash`、`.staging`、
///   macOS 的 `._x`、编辑器临时目录……）；
/// * `*.tmp` → 不算（存量设备的工程/安装目录里可能还留着旧版没点前缀的临时文件）。
bool isPackageContentPath(String relPosix) {
  if (relPosix.isEmpty) return false;
  for (final segment in relPosix.split('/')) {
    if (segment.isEmpty || segment.startsWith('.')) return false;
  }
  return !relPosix.toLowerCase().endsWith('.tmp');
}

/// 文本型包文件（`json` / `md` / `txt` / `csv`）。
///
/// 其余一律按二进制处理：内容不进内存（只留 key），哈希分块流式算。
bool isTextPackFile(String relPosix) {
  final lower = relPosix.toLowerCase();
  return lower.endsWith('.json') ||
      lower.endsWith('.md') ||
      lower.endsWith('.txt') ||
      lower.endsWith('.csv');
}
