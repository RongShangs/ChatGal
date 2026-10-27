import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgal/app/app_services.dart';
import 'package:chatgal/features/session/chat_page.dart';
import 'package:chatgal/features/settings/api_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

const ref = PackageRef(
  packageId: 'test.completion',
  version: '1',
  contentHash: 'test',
);

class ControlledProvider implements DialogueProvider {
  final requests = <GenerateRequest>[];
  final results = <Completer<ProviderResult>>[];
  final callbacks = <void Function(String)?>[];
  final agentResults = <Completer<ProviderResult>>[];
  final agentTokens = <CancelToken>[];

  @override
  Future<ProviderResult> generate(
    GenerateRequest request, {
    CancelToken? cancel,
    void Function(String)? onDelta,
  }) {
    // Hold agent responses independently to verify that they never block input.
    if (request.messages.any(
      (m) => m['role'] == 'system' && (m['content'] ?? '').contains('立绘'),
    )) {
      final done = Completer<ProviderResult>();
      agentResults.add(done);
      agentTokens.add(cancel!);
      return done.future;
    }
    requests.add(request);
    callbacks.add(onDelta);
    final done = Completer<ProviderResult>();
    results.add(done);
    return done.future;
  }

  void complete(int index, String text) {
    results[index].complete(
      ProviderResult.ok(
        response: parseAiResponse(text).response!,
        rawText: text,
      ),
    );
  }
}

class Settings extends ApiSettingsStore {
  Settings(super.rootDir, this.provider, this.stream);
  final ControlledProvider provider;
  final bool stream;
  @override
  AppSettings load() => AppSettings.empty.copyWith(streamOutput: stream);
  @override
  DialogueProvider createProvider() => provider;
}

class Packages extends PackageStore {
  Packages(super.rootDir);
  @override
  PackageRef? findExact(String id, String version, String hash) => ref;
}

class Services implements AppServices {
  Services(this.root, ControlledProvider provider, bool stream)
    : api = Settings(root.path, provider, stream);
  @override
  final Directory root;
  @override
  final Settings api;
  @override
  late final packages = Packages(root.path);
  @override
  late final saves = SaveRepository(rootDir: root.path, packages: packages);
  @override
  PlaySessionData loadPlaySession(PackageRef ref) {
    final character = CharacterDef.fromJson({
      'id': '测试',
      'prompt': '测试角色',
      'states': ['校服'],
      'emotions': ['平常'],
      'defaultState': '校服',
      'defaultEmotion': '平常',
    });
    final scene = SceneDef.fromJson({
      'displayName': '测试',
      'background': '',
      'narration': '场景',
      'characters': [
        {'charId': '测试', 'state': '校服', 'emotion': '平常'},
      ],
      'target': <Object?>[],
    }, id: 'start');
    final graph = SceneGraph(scenes: {'start': scene}, entrypoint: 'start');
    return PlaySessionData(
      characterName: '测试',
      packageTitle: '测试',
      packageIntro: '',
      characterPrompt: '',
      installDir: root.path,
      sceneGraph: graph,
      content: PackageContent(
        manifest: const PackageManifest(
          packageId: 'test.completion',
          version: '1',
          name: '测试',
          author: 'test',
          description: '',
        ),
        characters: [character],
        variables: [],
        scenes: graph.scenes,
        sceneGraph: graph,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(ready(), isTrue);
}

void main() {
  for (final stream in [true, false]) {
    testWidgets(
      '${stream ? 'stream' : 'typewriter'} blocks sending until reply and memory are complete',
      (tester) async {
        final root = Directory.systemTemp.createTempSync('chatgal_completion_');
        addTearDown(() async {
          for (var attempt = 0; ; attempt++) {
            try {
              if (root.existsSync()) await root.delete(recursive: true);
              break;
            } on FileSystemException {
              if (attempt >= 20) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 25));
            }
          }
        });
        final provider = ControlledProvider();
        final services = Services(root, provider, stream);
        final slot = (await tester.runAsync(
          () => services.saves.create(
            label: '测试',
            packageRef: ref,
            storyId: 'start',
            world: const WorldSnapshot(
              variables: {'day': 1},
              characters: {},
              story: {'storyId': 'start', 'nodeId': 'start'},
              presentation: {},
              eventHistory: {},
              rngState: 1,
            ),
          ),
        ))!;
        await tester.pumpWidget(
          MaterialApp(
            home: ChatPage(
              services: services,
              packageRef: ref,
              saveId: slot.saveId,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '第一句');
        await tester.tap(find.byKey(const ValueKey('chat-send-button')));
        await tester.pump();
        expect(provider.requests, hasLength(1));
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isTrue,
        );
        await tester.enterText(find.byType(TextField), '第二句');
        final reply = '第一轮完整回复' * 20;
        if (stream) {
          provider.callbacks[0]!('第一轮');
        } else {
          provider.complete(0, reply);
        }
        await tester.pump(const Duration(milliseconds: 32));
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isTrue,
        );
        final sendButton = find.byKey(const ValueKey('chat-send-button'));
        expect(tester.widget<IconButton>(sendButton).onPressed, isNull);
        expect(
          find.descendant(
            of: sendButton,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        final decoration = tester
            .widget<TextField>(find.byType(TextField))
            .decoration!;
        expect(decoration.hint, isNull);
        expect(decoration.hintText, '说什么(做什么)');
        await tester.tap(find.byKey(const ValueKey('chat-send-button')));
        await tester.pump();
        expect(provider.requests, hasLength(1));
        if (stream) {
          expect(
            provider.requests,
            hasLength(1),
            reason: 'first response is still in flight',
          );
          provider.callbacks[0]!(reply.substring('第一轮'.length));
          provider.complete(0, reply);
        }
        await waitFor(
          tester,
          () => tester.widget<IconButton>(sendButton).onPressed != null,
        );
        expect(
          provider.requests,
          hasLength(1),
          reason: 'no queued or automatic send',
        );
        expect(provider.agentResults, hasLength(1));
        expect(
          find.descendant(
            of: sendButton,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        expect(provider.agentResults.single.isCompleted, isFalse);
        expect(provider.agentTokens.single.isCancelled, isFalse);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '第二句',
        );
        await tester.tap(find.byKey(const ValueKey('chat-send-button')));
        await waitFor(tester, () => provider.requests.length == 2);
        expect(
          provider.agentTokens.first.isCancelled,
          isTrue,
          reason: 'cancel the previous agent when sending, not when the new reply arrives',
        );
        const stale =
            '{"replyExpression":"平常","replyPortrait":"校服_平常",'
            '"suggestedReplies":["旧轮次推荐","旧轮次推荐二"]}';
        provider.agentResults.first.complete(
          ProviderResult.ok(
            response: parseAiResponse('ignored').response!,
            rawText: stale,
          ),
        );
        await tester.pump();
        expect(find.text('旧轮次推荐'), findsNothing);
        final context = provider.requests[1].messages
            .map((m) => m['content'])
            .join('\n');
        expect(context, contains(reply));
        expect(context, contains('第一句'));
        expect(context, contains('第二句'));
        if (stream) provider.callbacks[1]!('第二轮回复');
        provider.complete(1, '第二轮回复');
        await waitFor(tester, () {
          final saved = services.saves.load(slot.saveId).slot!;
          return jsonEncode(saved.memoryCheckpoint).contains('第二轮回复');
        });
        final saved = services.saves.load(slot.saveId).slot!;
        final memory = jsonEncode(saved.memoryCheckpoint);
        expect(memory, contains(reply));
        expect(
          saved.messageCheckpoint.where((m) => m['role'] == 'user'),
          hasLength(2),
        );
        expect(find.textContaining('session busy'), findsNothing);
        expect(provider.agentResults, hasLength(2));
        const current =
            '{"replyExpression":"平常","replyPortrait":"校服_平常",'
            '"suggestedReplies":["本轮推荐","本轮推荐二"]}';
        provider.agentResults[1].complete(
          ProviderResult.ok(
            response: parseAiResponse('ignored').response!,
            rawText: current,
          ),
        );
        await tester.pump();
        expect(find.text('本轮推荐'), findsOneWidget);
        await tester.enterText(find.byType(TextField), '失败后保留');
        await tester.tap(find.byKey(const ValueKey('chat-send-button')));
        await tester.pump();
        provider.results[2].complete(
          const ProviderResult.failed(
            status: ProviderStatus.offline,
            error: 'offline',
          ),
        );
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isTrue,
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '失败后保留',
        );
        await tester.tap(find.byKey(const ValueKey('chat-send-button')));
        await tester.pump();
        await tester.enterText(find.byType(TextField), '正在编辑的新草稿');
        provider.results[3].complete(
          const ProviderResult.failed(
            status: ProviderStatus.offline,
            error: 'offline',
          ),
        );
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '正在编辑的新草稿',
        );
        expect(tester.widget<IconButton>(sendButton).onPressed, isNotNull);
        // Drain real file IO and fake-zone continuations before disposing the page.
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 10));
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
      },
    );
  }
}
