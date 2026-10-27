import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// 聊天页的几何常量与公式：**游戏页与「游戏画面设置」的预览窗共用这一份**。
///
/// 上一版的问题就出在没有共用：预览按「立绘高度 + 留白」摆气泡，
/// 而游戏页底部其实是一整块 `Column`（立绘 + 输入栏），`ListView` 的底部留白
/// 却只按立绘高度算 —— 于是预览里气泡离立绘还有一段空隙，进游戏却贴在立绘上。
/// 现在两边都走 [messageBottomInset]，游戏页把实测的底部块高度传进来。
///
/// 留白公式补全之后，「留白调整」的默认值就该是 **0**：底部整块已经被让开了，
/// 再默认加一段就只是凭空的缝隙。这个值现在是**可正可负**的微调量：
/// 正数把消息流往上推，负数把它压下来靠近（甚至压住）立绘。
abstract final class ChatLayout {
  static const double portraitMin = 140;
  static const double portraitMax = 420;

  /// 留白调整的下限：负值让消息靠近立绘；再往负就纯粹是把气泡藏到立绘背后，
  /// 没有意义，也容易让人以为「消息丢了」。
  static const double padMin = -160;
  static const double padMax = 120;

  /// 消息流留白调整的默认值：0（底部整块已经让开，不需要额外缝隙）。
  static const double defaultChatBottomPad = 0;

  /// 历史版本的默认值 —— 只用于迁移（用户从没手动拖过时归零），见
  /// [ApiSettingsStore] 里的 `_readChatBottomPad`。
  static const List<double> legacyDefaultPads = [35, 60];

  /// 游戏页最近一次实测到的**输入栏**高度（逻辑像素）；0 = 还没进过游戏。
  ///
  /// 输入栏高度取决于机型安全区与快捷回复的换行情况，猜不准，所以由游戏页量完
  /// 发布出来；设置页的预览窗拿它当真值（进过一次游戏后预览就与实机一致）。
  /// 发布的是「输入栏」而不是整个底部块：改立绘高度后这个值依然成立。
  static final ValueNotifier<double> measuredInputBarHeight =
      ValueNotifier<double>(0);

  static double portrait(double v) => v.clamp(portraitMin, portraitMax);
  static double pad(double v) => v.clamp(padMin, padMax);

  /// 消息流底部留白：**底部整块**（立绘 + 输入栏）之上再让出 [chatBottomPad]。
  ///
  /// [bottomBlockHeight] 是游戏页实测的底部区块高度（立绘容器 + 输入栏）。
  /// 拿不到实测值时（首帧、设置页预览）退回「立绘高度」——也就是旧行为，
  /// 不会比改动前更差。
  ///
  /// 调整值可以为负，但**结果永远夹到 ≥ 0**：ScrollView 的 padding 不接受负数，
  /// 传下去会炸布局；负到极限就是「贴着屏幕底」。
  static double messageBottomInset({
    required double portraitHeight,
    required double chatBottomPad,
    double bottomBlockHeight = 0,
  }) {
    final base =
        math.max(bottomBlockHeight, portrait(portraitHeight)) + pad(chatBottomPad);
    return math.max(0, base);
  }
}
