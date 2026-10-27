/// Central install limits (documented in author guide later).
class InstallLimits {
  const InstallLimits({
    this.maxZipBytes = 256 * 1024 * 1024,
    // 解压后的总字节上限：**1GB，刻意留宽**。
    // 之前有人提议收到 256MB（理由是「手机上一份包不会真的解压成 1GB」），
    // 但那会拒掉以前装得下的自制包/工程 —— 属于会改变「什么包能被装进来」的行为，
    // 产品上不收紧。真正的防线是上面那条 zip 体积上限（256MB）与下面的条目数上限。
    this.maxExtractedBytes = 1024 * 1024 * 1024,
    this.maxEntries = 5000,
    this.maxJsonBytes = 8 * 1024 * 1024,
  });

  final int maxZipBytes;
  final int maxExtractedBytes;
  final int maxEntries;
  final int maxJsonBytes;

  static const defaults = InstallLimits();
}
