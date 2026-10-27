import 'package:chatgal/design_system/tokens.dart';
import 'package:chatgal/features/session/leave_status_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gal_ai/gal_ai.dart';

/// 换场等待期那张小卡（画面中上部）。
///
/// 它出现的那段时间玩家什么都做不了，所以三件事必须有保证：
/// 说清楚在做什么、进度条反映**真实步数**、等待期不给任何无限动画。
Future<void> pumpCard(WidgetTester tester, LeaveStatus status) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: LeaveStatusCard(status: status, theme: ChatGalTheme.violet),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('记忆阶段：点名正在整理谁，进度条按真实步数走', (tester) async {
    await pumpCard(
      tester,
      const LeaveStatus(
        phase: LeavePhase.memory,
        done: 1,
        total: 3,
        owner: '戒戒',
        seconds: 4,
      ),
    );
    expect(find.byKey(const ValueKey('leave-status-card')), findsOneWidget);
    expect(find.text('正在整理本幕的记忆（戒戒）'), findsOneWidget);
    expect(find.text('第 1/3 步 · 已等待 4 秒'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(
      bar.value,
      closeTo(1 / 3, 0.001),
      reason: '进度条要反映真实步数，而不是按时间假推进',
    );
  });

  testWidgets('结算阶段：文案换成结算，进度比例照旧', (tester) async {
    await pumpCard(
      tester,
      const LeaveStatus(
        phase: LeavePhase.settlement,
        done: 2,
        total: 3,
        owner: '戒戒',
        seconds: 12,
      ),
    );
    expect(find.text('正在结算本幕的变化'), findsOneWidget);
    expect(find.text('第 2/3 步 · 已等待 12 秒'), findsOneWidget);
  });

  testWidgets('还不知道要几步时不画进度条，只报已等待秒数', (tester) async {
    await pumpCard(
      tester,
      const LeaveStatus(phase: LeavePhase.memory, seconds: 7),
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('已等待 7 秒'), findsOneWidget);
  });

  testWidgets('等待期没有任何无限动画（否则「等它转完」的测试会卡死）', (tester) async {
    await pumpCard(tester, const LeaveStatus(done: 2, total: 2, seconds: 3));
    expect(find.text('正在整理本幕的记忆'), findsOneWidget);
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: '转圈是无限动画，等待期用它会让 pumpAndSettle 永远不结束',
    );
    await tester.pumpAndSettle();
  });
}
