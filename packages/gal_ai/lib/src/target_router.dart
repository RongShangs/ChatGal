import 'package:gal_protocol/gal_protocol.dart';

/// 出口判定的**唯一实现**：情景与事件共用同一套规则。
///
/// * 按数组顺序轮询，**首个 `require` 成立的块被锁定**；
/// * 锁定后在该块的 `kind` 数组里**等概率**取一个（3 个各 1/3；两个指向同一
///   目标就是 2/3）；
/// * 没有任何块成立（或压根没有块）→ 返回 null，调用方提示
///   「暂时不能进入下一阶段噢」，玩家留在原地继续对话。
class TargetRouter {
  TargetRouter();

  /// `require` 解析结果缓存：同一份包里的表达式只解析一次。
  final Map<String, RequireExpr> _cache = {};

  bool matches(TargetBlock block, WorldSnapshot world) {
    final req = block.require;
    if (req == null || req.trim().isEmpty) return true;
    final expr = _cache[req] ??= RequireExpr.parse(req);
    return expr.evaluate(world);
  }

  /// 块内等概率随机。[rngState] 来自存档，所以同一份存档回放结果一致。
  ExitTarget? _pick(TargetBlock block, int rngState) {
    final kinds = block.kinds;
    if (kinds.isEmpty) return null;
    if (kinds.length == 1) return kinds.first;
    final rng = GalRng(scatterSeed(rngState));
    final idx = (rng.nextDouble() * kinds.length).floor();
    return kinds[idx.clamp(0, kinds.length - 1)];
  }

  ExitTarget? route(
    List<TargetBlock> blocks,
    WorldSnapshot world, {
    required int rngState,
  }) {
    for (final block in blocks) {
      if (!matches(block, world)) continue;
      final t = _pick(block, rngState);
      if (t != null) return t;
    }
    return null;
  }
}
