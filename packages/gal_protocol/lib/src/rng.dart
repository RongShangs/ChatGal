/// 确定性 xorshift32 RNG。状态跟着存档走，同样的状态 → 同样的结果。
///
/// 从已删除的 gal_core 搬过来：它是自足的小工具，不属于「引擎」。
class GalRng {
  GalRng(this.state) {
    if (state == 0) state = 0x9E3779B9;
  }

  int state;

  /// Next unsigned 32-bit value.
  int nextUint32() {
    var x = state;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >>> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    state = x & 0xFFFFFFFF;
    return state;
  }

  /// Integer in [0, exclusiveMax).
  int nextInt(int exclusiveMax) {
    if (exclusiveMax <= 0) {
      throw ArgumentError.value(exclusiveMax, 'exclusiveMax', 'must be > 0');
    }
    return nextUint32() % exclusiveMax;
  }

  /// Double in [0, 1).
  double nextDouble() => nextUint32() / 0x100000000;

  GalRng copy() => GalRng(state);
}

/// 把一个单调递增的小计数器（`world.rngState`）散列成分布良好的种子。
///
/// 直接用计数器的前几个值喂 xorshift 会让它**几乎固定**命中第一个分支
/// （历史上「加权随机永不生效」就是这个原因）；先过一遍 lowbias32 mix，
/// 相邻状态才会落在 [0,1) 各处，同时保持可复现。
int scatterSeed(int state) {
  var x = state & 0xFFFFFFFF;
  x = ((x ^ (x >>> 16)) * 0x7FEB352D) & 0xFFFFFFFF;
  x = ((x ^ (x >>> 15)) * 0x846CA68B) & 0xFFFFFFFF;
  return (x ^ (x >>> 16)) & 0xFFFFFFFF;
}
