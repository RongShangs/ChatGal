import 'package:chatgal/features/splash/splash_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 开屏 → 主页要**交叉淡入淡出**，不能「啪」一下把开屏抹掉（用户反馈「有点突兀」）。
///
/// 这条测试只盯 `SplashFade` 这个过渡壳子：两个根页面必须同时在树上、透明度反向变化，
/// 过渡结束后旧的那个才被摘掉。接进真实启动流程的部分（`main.dart` 的 `home:`）
/// 只能靠真机看 —— 这里至少把「交叉淡」这件事钉死。
void main() {
  testWidgets('开屏 → 主页：交叉淡入淡出（不是直接消失）', (tester) async {
    var showFirst = true;
    late StateSetter setShow;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setShow = setState;
            return SplashFade(
              showFirst: showFirst,
              first: const _Box('开屏'),
              second: const _Box('主页'),
            );
          },
        ),
      ),
    );

    expect(find.text('开屏'), findsOneWidget);
    expect(find.text('主页'), findsNothing);

    /// 某个页面的淡入淡出值（AnimatedSwitcher 给每个孩子套的 FadeTransition）。
    double fadeOf(String text) => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.text(text),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;

    setShow(() => showFirst = false);
    await tester.pump(); // 过渡开始的那一帧

    // 两边**同时**在树上：这才是交叉，而不是换掉
    expect(find.text('开屏'), findsOneWidget);
    expect(find.text('主页'), findsOneWidget);
    final firstAtStart = fadeOf('开屏');
    final secondAtStart = fadeOf('主页');
    expect(firstAtStart, greaterThan(0.5), reason: '旧页面应该还在（正在淡出）');
    expect(secondAtStart, lessThan(0.5), reason: '新页面应该刚开始淡入');

    await tester.pump(const Duration(milliseconds: 200));
    expect(fadeOf('主页'), greaterThan(secondAtStart), reason: '新页面在淡入');
    expect(fadeOf('开屏'), lessThan(firstAtStart), reason: '旧页面在淡出');

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('主页'), findsOneWidget);
    expect(fadeOf('主页'), moreOrLessEquals(1.0, epsilon: 0.01));
    expect(find.text('开屏'), findsNothing, reason: '过渡结束后旧页面要摘掉');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}

/// 两个占位根页面（整屏、颜色不同，便于看清交叉淡入淡出）。
class _Box extends StatelessWidget {
  const _Box(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: label == '开屏' ? const Color(0xFFAA96DA) : Colors.white,
      child: Center(child: Text(label)),
    );
  }
}
