import 'package:chatgal/features/session/chat_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatLayout 夹取', () {
    test('立绘高度夹在 140~420', () {
      expect(ChatLayout.portrait(10), 140);
      expect(ChatLayout.portrait(999), 420);
      expect(ChatLayout.portrait(260), 260);
    });

    test('留白调整可正可负，夹在 -160~120', () {
      expect(ChatLayout.pad(-5), -5);
      expect(ChatLayout.pad(-20), -20);
      expect(ChatLayout.pad(-999), ChatLayout.padMin);
      expect(ChatLayout.pad(999), ChatLayout.padMax);
      expect(ChatLayout.pad(60), 60);
    });
  });

  group('消息流底部留白', () {
    test('拿不到实测值时退回「立绘高度 + 留白调整」（旧行为）', () {
      expect(
        ChatLayout.messageBottomInset(portraitHeight: 260, chatBottomPad: 60),
        320,
      );
    });

    test('有实测的底部整块高度时以它为准', () {
      // 立绘 260 + 输入栏 130 = 390，再加 60 留白调整。
      expect(
        ChatLayout.messageBottomInset(
          portraitHeight: 260,
          chatBottomPad: 60,
          bottomBlockHeight: 390,
        ),
        450,
      );
    });

    test('实测值比立绘还小时不缩水（绝不会把气泡塞到立绘底下）', () {
      expect(
        ChatLayout.messageBottomInset(
          portraitHeight: 260,
          chatBottomPad: 60,
          bottomBlockHeight: 100,
        ),
        320,
      );
    });

    test('改动前后差的就是那一段输入栏：这正是「预览与实际不符」的量', () {
      final old =
          ChatLayout.messageBottomInset(portraitHeight: 260, chatBottomPad: 60);
      final fixed = ChatLayout.messageBottomInset(
        portraitHeight: 260,
        chatBottomPad: 60,
        bottomBlockHeight: 260 + 128,
      );
      expect(fixed - old, 128);
    });

    test('负的留白调整把消息压下来靠近立绘，公式就是加一个负数', () {
      final base = ChatLayout.messageBottomInset(
        portraitHeight: 260,
        chatBottomPad: 0,
        bottomBlockHeight: 390,
      );
      final pulled = ChatLayout.messageBottomInset(
        portraitHeight: 260,
        chatBottomPad: -60,
        bottomBlockHeight: 390,
      );
      expect(base, 390);
      expect(pulled, 330);
    });

    test('调到极负也不会算出负 padding（ScrollView 不接受负数）', () {
      // 底部整块很小 + 负到底：结果夹到 0，而不是负数。
      expect(
        ChatLayout.messageBottomInset(
          portraitHeight: ChatLayout.portraitMin,
          chatBottomPad: ChatLayout.padMin,
          bottomBlockHeight: 100,
        ),
        0,
      );
    });

    test('默认留白调整是 0（底部整块已经让开，不需要额外缝隙）', () {
      expect(ChatLayout.defaultChatBottomPad, 0);
      expect(ChatLayout.defaultChatBottomPad % 5, 0);
      expect(
        ChatLayout.messageBottomInset(
          portraitHeight: 260,
          chatBottomPad: ChatLayout.defaultChatBottomPad,
          bottomBlockHeight: 390,
        ),
        390,
      );
    });

    test('历史默认值被登记下来（35 与 60 都要能迁到 0）', () {
      expect(ChatLayout.legacyDefaultPads, containsAll(<double>[35, 60]));
      expect(ChatLayout.legacyDefaultPads, isNot(contains(0)));
    });
  });

  test('输入栏实测值默认是 0（= 还没进过游戏）', () {
    expect(ChatLayout.measuredInputBarHeight.value, 0);
  });
}
