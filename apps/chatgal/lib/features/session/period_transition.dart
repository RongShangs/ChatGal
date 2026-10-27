import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';

/// 换幕过场：全屏薄纱淡入 → 「第 N 天 / 情景名 / 气氛句」依次浮现 → 一道斜光带
/// 扫过 → 收束淡出。自己管一个 AnimationController，跑完回调 [onFinished]，
/// 由父层据此把它从树上摘下来。
///
/// 背景有两种：
/// * 有 [backgroundPath]（要进入那一幕的聊天背景）→ 铺那张图 + **压暗 + 轻微模糊**，
///   文字走浅色 —— 过场淡出之后就落进同一张图，换幕是连续的；
/// * 没有 → 退回原来的主题色薄纱（文字走深色）。
class PeriodTransitionOverlay extends StatefulWidget {
  const PeriodTransitionOverlay({
    super.key,
    required this.theme,
    required this.day,
    required this.sceneName,
    required this.onFinished,
    this.atmosphere = '',
    this.backgroundPath,
  });

  final ChatGalTheme theme;
  final int day;

  /// 情景展示名（第 N 天 · 情景名 里的那一段）。
  final String sceneName;

  /// 包声明的转场气氛（地点氛围描写）。空串时不显示。
  final String atmosphere;

  /// 要进入那一幕的聊天背景（绝对路径）。null = 用主题色薄纱。
  final String? backgroundPath;
  final VoidCallback onFinished;

  @override
  State<PeriodTransitionOverlay> createState() =>
      _PeriodTransitionOverlayState();
}

class _PeriodTransitionOverlayState extends State<PeriodTransitionOverlay>
    with SingleTickerProviderStateMixin {
  static const _total = Duration(milliseconds: 1700);
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _total,
  );

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onFinished();
    });
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _phase(double t, double a, double b, Curve curve) {
    if (t <= a) return 0;
    if (t >= b) return 1;
    return curve.transform((t - a) / (b - a));
  }

  /// 内容浮现 0→1，随后收束 1→0。
  double _contentOpacity(double t) =>
      (_phase(t, 0.06, 0.34, Curves.easeOutCubic) *
              (1 - _phase(t, 0.74, 1.0, Curves.easeInCubic)))
          .clamp(0.0, 1.0);

  double _contentShiftY(double t) =>
      (1 - _phase(t, 0.06, 0.34, Curves.easeOutCubic)) * 28 -
      _phase(t, 0.74, 1.0, Curves.easeInCubic) * 20;

  /// 薄纱遮罩：淡入 → 保持 → 淡出。
  double _veilOpacity(double t) => (_phase(t, 0.0, 0.18, Curves.easeOut) *
          (1 - _phase(t, 0.72, 1.0, Curves.easeInCubic)))
      .clamp(0.0, 1.0);

  /// 中央横线：从中间向两侧展开。
  double _ruleScale(double t) =>
      _phase(t, 0.20, 0.44, Curves.easeOutCubic) *
      (1 - _phase(t, 0.78, 1.0, Curves.easeIn));

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final background = widget.backgroundPath;
    final onImage = background != null;
    // 有背景图时文字走浅色（图上要读得清），没有时走主题的正文色。
    // 这两项不随时间变化，放在外层没问题。
    final ink = onImage ? Colors.white : t.ink;
    final sub = onImage ? Colors.white.withValues(alpha: 0.82) : t.sub;

    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            // ⚠ **所有随时间变化的量都必须在这里算**。
            // AnimatedBuilder 每帧只重跑这个 builder；外面那层 `build()` 不会重跑，
            // 在外层算出来的 `veil` / `content` 会**冻在过场开始那一帧（全是 0）**，
            // 整层永远透明 —— 只有页面碰巧因为别的原因重建时才按当刻进度闪一下，
            // 表现就是「过场时有时无、出现和消失都很突兀」。
            final value = _c.value;
            final veil = _veilOpacity(value);
            final content = _contentOpacity(value);
            // 天数、情景名、气氛句错开一点点入场，读起来有节奏。
            final dayIn = _phase(value, 0.08, 0.34, Curves.easeOutCubic);
            final sceneIn = _phase(value, 0.14, 0.42, Curves.easeOutBack);
            final atmoIn = _phase(value, 0.26, 0.52, Curves.easeOut);

            return LayoutBuilder(
              builder: (context, box) {
                final w = box.maxWidth;
                final h = box.maxHeight;
                // 斜光带从左外侧扫到右外侧。
                final sweep = _phase(value, 0.18, 0.66, Curves.easeInOut);
                final sweepX = -0.35 * w + sweep * (w * 1.7);

                return Opacity(
                  opacity: veil,
                  child: Stack(
                    children: [
                      if (onImage)
                        // 要进入那一幕的背景：轻微模糊 + 压暗，让上面的文字读得清，
                        // 又不至于把这一幕的画面挡成一个色块。
                        Positioned.fill(
                          child: ImageFiltered(
                            imageFilter: ui.ImageFilter.blur(
                              sigmaX: 6,
                              sigmaY: 6,
                            ),
                            // 模糊会把边缘收进来，稍微放大一点，别露出毛边。
                            child: Transform.scale(
                              scale: 1.06,
                              child: Image.file(
                                File(background),
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                                errorBuilder: (context, error, stack) =>
                                    const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        ),
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: onImage
                                // 有图：暗色渐变（上下更暗，中间留一点画面）
                                ? LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.black.withValues(alpha: 0.62),
                                      Colors.black.withValues(alpha: 0.34),
                                      Colors.black.withValues(alpha: 0.7),
                                    ],
                                    stops: const [0.0, 0.5, 1.0],
                                  )
                                // 没图：保持原来的主题色薄纱
                                : LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      t.bg.withValues(alpha: 0.97),
                                      t.card.withValues(alpha: 0.99),
                                      t.bg.withValues(alpha: 0.97),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                      // 中央一团淡淡的主色光晕，给平面底子一点体积。
                      Positioned(
                        left: -w * 0.25,
                        right: -w * 0.25,
                        top: h * 0.5 - w * 0.55,
                        height: w * 1.1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                t.accent.withValues(alpha: 0.18 * content),
                                t.accent.withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // 斜光带
                      Positioned(
                        left: sweepX,
                        top: -h * 0.35,
                        width: w * 0.45,
                        height: h * 1.7,
                        child: Transform.rotate(
                          angle: -0.32,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.white.withValues(alpha: 0.0),
                                  Colors.white.withValues(
                                    alpha: 0.16 * veil,
                                  ),
                                  Colors.white.withValues(alpha: 0.0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Center(
                        child: Transform.translate(
                          offset: Offset(0, _contentShiftY(value)),
                          child: Opacity(
                            opacity: content,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Opacity(
                                  opacity: dayIn,
                                  child: Text(
                                    '第 ${widget.day} 天',
                                    style: TextStyle(
                                      fontSize: 13,
                                      letterSpacing: 6,
                                      fontWeight: FontWeight.w600,
                                      color: sub,
                                      shadows: onImage
                                          ? const [
                                              Shadow(
                                                blurRadius: 8,
                                                color: Colors.black87,
                                              ),
                                            ]
                                          : null,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Transform.scale(
                                  scale: 0.86 + 0.14 * sceneIn,
                                  child: Text(
                                    widget.sceneName,
                                    style: TextStyle(
                                      fontSize: 34,
                                      height: 1.1,
                                      letterSpacing: 6,
                                      fontWeight: FontWeight.w700,
                                      color: ink,
                                      shadows: onImage
                                          ? const [
                                              Shadow(
                                                blurRadius: 14,
                                                color: Colors.black87,
                                              ),
                                            ]
                                          : null,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                // 从中间向两侧展开的细线
                                SizedBox(
                                  height: 1,
                                  child: Transform.scale(
                                    scaleX: _ruleScale(value),
                                    child: Container(
                                      width: 148,
                                      height: 1,
                                      // 图上用浅色细线（主题主色在暗底上会糊）
                                      color: onImage
                                          ? Colors.white.withValues(alpha: 0.75)
                                          : t.accent.withValues(alpha: 0.6),
                                    ),
                                  ),
                                ),
                                if (widget.atmosphere.trim().isNotEmpty) ...[
                                  const SizedBox(height: 16),
                                  // 包声明的转场气氛（该地点的氛围描写）
                                  Opacity(
                                    opacity: atmoIn,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                      ),
                                      child: Text(
                                        widget.atmosphere,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          height: 1.7,
                                          color: sub,
                                          shadows: onImage
                                              ? const [
                                                  Shadow(
                                                    blurRadius: 8,
                                                    color: Colors.black87,
                                                  ),
                                                ]
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
