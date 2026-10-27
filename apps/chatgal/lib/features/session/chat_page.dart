import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal_ai/gal_ai.dart';
import 'package:gal_protocol/gal_protocol.dart';

import '../../app/app_logger.dart';
import '../../app/app_services.dart';
import '../../design_system/tokens.dart';
import '../settings/api_settings.dart';
import '../settings/chat_font.dart';
import '../tts/tts_service.dart';
import '../tts/tts_settings.dart';
import 'action_span.dart';
import 'chat_layout.dart';
import 'leave_status_card.dart';
import 'memory_page.dart';
import 'period_transition.dart';
import 'portrait_bg_remover.dart';
import 'save_position_check.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    this.theme = ChatGalTheme.violet,
    this.services,
    this.packageRef,
    this.saveId,
    this.initialSaveLabel,
  });

  final ChatGalTheme theme;
  final AppServices? services;
  final PackageRef? packageRef;
  final String? saveId;
  final String? initialSaveLabel;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  /// Top bar control height: matches memory pill (24 content + 8+8 padding).
  static const _topBarHeight = 40.0;

  /// 记忆阈值：**唯一来源是游戏外设置**（设置 → 记忆）。存档不保存它们，
  /// 游戏内也不提供调整入口。
  MemoryThresholds _memoryThresholds = MemoryThresholds.defaults;

  /// 设置里的「流式输出」：开则网络增量直接进打字机。
  bool _streamOutput = true;

  late final TurnCoordinator _coord;
  late TransitionCoordinator _leaveCoord;

  /// All characters' memory: one L1 active window + one tree each. Single
  /// source of truth — the legacy MemoryStore was removed, not kept in parallel.
  late MemoryBank _memories;
  late MemoryRuntime _memoryRt;
  late final MemoryContextAssembler _ctxAssembler;
  EventPlayState? _eventPlay;
  late final EventCoordinator _eventCoord;

  /// 出口判定：情景换幕与事件收尾共用同一套规则。
  final TargetRouter _router = TargetRouter();
  int _revision = 0;
  RuntimeCursor _cursor = const RuntimeCursor(
    mode: RuntimeCursor.modeStoryChat,
  );
  final List<String> _committedTransitions = [];
  final List<String> _appliedSettlementIds = [];

  /// 事件收集台账：已经触发过的事件 id（持久化在存档的 pendingGalleryUnlocks）。
  final Set<String> _unlockedEventIds = {};
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// 输入框焦点：发送校验通过后主动收起键盘。
  final _inputFocus = FocusNode();

  /// 已经播过入场动画的气泡 id。一条消息只入场一次，滚出可视区再滚回来
  /// 也不会重放（ListView 销毁元素后重建时会重新问一次要不要播）。
  final Set<int> _bubbleEntered = {};
  bool _usingMock = true;
  PlaySessionData? _session;
  PackageRef? _ref;
  String _sessionId = 'demo';
  String? _saveId;
  String _characterName = '角色';
  String _systemPrompt = '';
  String? _cascadeState;
  final List<_ChatItem> _items = [];
  String _qr1 = '(轻轻点头)';
  String _qr2 = '别怕，我在';
  bool _busy = false;
  bool _streaming = false;

  /// 完整回复记录后启用发送；快捷回复在 agent 返回前保持灰色。
  bool _replyUnlocked = false;
  bool _qrLoading = false;
  Timer? _streamTimer;
  String _streamText = '';
  final _liveDelta = StringBuffer();
  bool _replyInFlight = false;
  Completer<void>? _textPlaybackDone;

  /// 时段切换过场：非空时铺在最上层；动画跑完清掉它并完成 [_periodDone]。
  _PeriodAnim? _periodAnim;
  Completer<void>? _periodDone;
  int _periodSerial = 0;

  /// 事件收尾进行中：挡住重复点击，避免 onFinish 的 effects 叠加两次。
  bool _eventFinishing = false;

  /// 记忆整理闸：防止 L1 坍缩与后台高层整理同时跑在同一份记忆上。
  bool _memoryBusy = false;
  int _memoryEpoch = 0;

  /// 允许下一次系统返回直接 pop（appShell 出口用）。
  /// PopScope(canPop:false) 会拦截**所有** pop，包括程序内 maybePop ——
  /// 出口是「回主页」时必须真的弹回去，不能又弹出「确认离开」对话框。
  bool _allowSystemPop = false;

  /// 当前这条回复的操作代次：聊天 / agent / 展示共用。
  /// 页面销毁或新一轮回复开始时 +1，迟到的 agent 结果据此作废。
  int _replyEpoch = 0;

  /// 立绘 agent 的取消令牌（与聊天协调器分开：agent 不写消息、不算回合）。
  CancelToken? _lookCancel;

  /// 真正弹回上一页（绕过 PopScope 的确认流程）。
  ///
  /// [force]=true 用于玩家在「保存失败」对话框里明确选择「仍然离开」：
  /// 此时不能因为 `_lastPersistError` 再把人拦住 —— 界面已经给了放弃进度的出口。
  /// 普通出口仍会在调用前检查保存失败，不会在未落盘时静默离开。
  Future<void> _popToHome({bool force = false}) async {
    if (!mounted) return;
    if (!force && _lastPersistError != null) return;
    setState(() => _allowSystemPop = true);
    // PopScope 在 rebuild 时才向路由登记 canPop。
    await WidgetsBinding.instance.endOfFrame;
    // 把这次玩的存档 id 交回主页：玩家从「新的开始」进来的话，主页记住的
    // 还是「新的开始」，退出后会跳回新档选择而不是刚建的那个档。
    if (mounted) await Navigator.of(context).maybePop(_saveId);
  }

  /// 气泡上的表情标签（来自 segments[].expressionId）。
  String _currentExpression = '';

  /// 本幕锁定的立绘状态（来自 enter.characters[].state）。
  String _clothing = '';

  /// 当前要用的立绘名：模型用 portraitId 选的那一张；没给就退回表情词。
  String _portraitRequest = '';
  String _replyLength = 'short';
  bool _followBottom = true;
  bool _showBg = true;

  /// 立绘容器高度（逻辑像素）：直接控制底部立绘区高度。
  /// 图片顶满容器高度并完整显示（contain）。
  double _portraitHeight = 200;

  /// 消息流留白调整：底部留白 = 底部整块（立绘 + 输入栏）+ 本值（可正可负）。
  /// 公式见 [ChatLayout.messageBottomInset]（设置页的预览窗用同一份）。
  double _chatBottomPad = ChatLayout.defaultChatBottomPad;

  /// 底部那一整块（立绘容器 + 输入栏）的**实测**高度。
  ///
  /// 之前这里只按立绘高度算留白，漏了输入栏，最后几条消息会落到立绘背后；
  /// 设置页预览按公式画、游戏里却不是那个样子（用户报的「预览与实际不符」）。
  /// 首帧拿不到实测值时为 0，[ChatLayout.messageBottomInset] 会退回旧行为。
  double _bottomBlockHeight = 0;

  /// 换场等待期（本幕 L1→L2 提炼 + 离场结算）的状态：非空时画面中上部有一张
  /// 小卡显示「在做什么、走到第几步、等了多久」。null = 没在等。
  LeaveStatus? _leaveStatus;
  Timer? _leaveTick;
  final GlobalKey _bottomBlockKey = GlobalKey();
  bool _bottomMeasureScheduled = false;

  /// 自动抠图：把立绘纯色背景替换为透明。
  bool _autoRemoveBg = false;

  /// 聊天区字体与字号（**只作用于对话气泡**，设置 → 外观 → 字体与字号）。
  String _chatFontId = kSystemFontId;
  double _chatFontSize = kChatFontSizeDefault;
  List<ImportedChatFont> _importedFonts = const [];

  /// 语音朗读：settings → 语音配置。null 表示没有 services（离线/测试构造）。
  TtsController? _tts;
  TtsSettings _ttsSettings = const TtsSettings();

  /// 正在朗读的那条气泡（用来把按钮切成「停止」）。用对象身份而不是下标：
  /// 消息列表会被重建，下标靠不住。
  Object? _speakingToken;

  WorldSnapshot _world = const WorldSnapshot(
    variables: {},
    characters: {},
    eventHistory: {},
    story: {'day': 1},
    presentation: {},
    rngState: 1,
  );
  final List<Map<String, Object?>> _messages = [];

  /// day 的**唯一权威**是扁平变量命名空间（manifest 注册的 `day`）。
  /// `story['day']` 只是同步写入的镜像，仅在没有变量时兜底。
  int get _day {
    final v = _world.variables['day'];
    if (v is num) return v.toInt();
    return (_world.story['day'] as num?)?.toInt() ?? 1;
  }

  /// 记忆缓冲进度要按**轮数**算：`l1CollapseAt` 的单位是「轮」，而气泡数
  /// 一轮有两条（玩家 + 角色），用气泡数会让进度环以约 2× 速度涨、提前变红。
  int get _l1RoundCount => _memories.windowOf(_owner).length;

  /// 该角色声明的默认表情（包说是什么就是什么，应用不写死）。
  /// 以**当前幕出场角色**为准；空角色幕退回包内第一个角色。
  String get _defaultEmotion {
    final char = _currentCharacter;
    return char?.defaultEmotion ?? '';
  }

  /// 当前说话角色：优先取本幕 `characters[]` 的第一位（一幕一人），
  /// 空角色幕 / 找不到时退回包内第一个角色。
  /// 不能固定取 `characters.first`：不同幕换人时会用错人格、立绘和记忆 owner。
  CharacterDef? get _currentCharacter {
    final session = _session;
    if (session == null) return null;
    final scene = _currentScene;
    if (scene != null) {
      for (final c in scene.characters) {
        if (c.charId.isEmpty) continue;
        final found = session.content.character(c.charId);
        if (found != null) return found;
      }
    }
    return session.content.characters.isEmpty
        ? null
        : session.content.characters.first;
  }

  /// 注册表里的上下限（保留给需要收口的调用方）。
  Map<String, ({num? min, num? max})> get _variableRanges =>
      _session?.content.variableRegistry.ranges ?? const {};

  /// Authority facts block: every registered variable at its current value,
  /// under the package's own id, so the model sees the real names.
  String _authorityFacts() {
    final parts = <String>['day=$_day'];
    final reg = _session?.content.variableRegistry;
    if (reg != null) {
      for (final v in reg.defs) {
        final value = _world.variables[v.id];
        if (value == null) continue;
        parts.add('${v.id}=$value');
      }
    }
    return parts.join(', ');
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    final dark = widget.theme.brightness == Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: widget.theme.card,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
      ),
    );

    final services = widget.services;
    _usingMock = services == null || !services.api.isConfigured;
    final provider = services?.api.createProvider() ?? MockDialogueProvider();
    _coord = TurnCoordinator(provider: provider);
    // 记忆阈值只在游戏外设置里。
    final settings = services?.api.load();
    _memoryThresholds = settings?.memory ?? MemoryThresholds.defaults;
    _replyLength = settings?.replyLength ?? 'short';
    _streamOutput = settings?.streamOutput ?? true;
    _portraitHeight = ChatLayout.portrait(settings?.portraitHeight ?? 200);
    _chatBottomPad = ChatLayout.pad(
      settings?.chatBottomPad ?? ChatLayout.defaultChatBottomPad,
    );
    _autoRemoveBg = settings?.autoRemoveBg ?? false;
    _chatFontId = settings?.chatFontId ?? kSystemFontId;
    _chatFontSize = settings?.chatFontSize ?? kChatFontSizeDefault;
    _importedFonts = settings?.importedFonts ?? const [];
    _ttsSettings = settings?.tts ?? const TtsSettings();
    final services0 = services;
    if (services0 != null && _ttsSettings.enabled) {
      _tts = TtsController(
        rootDir: services0.root.path,
        settingsSource: services0.api,
      )..addListener(_onTtsChanged);
      // 缓存目录顺手清一次，别让朗读音频无限长。
      unawaited(_tts!.pruneCache());
    }
    _memories = MemoryBank(thresholds: _memoryThresholds);
    // Offline (no API configured) → deterministic summarizer: it concatenates
    // and never invents, and never changes numbers.
    _memoryRt = MemoryRuntime(
      provider: _usingMock
          ? const DeterministicMemoryProvider()
          : DialogueMemoryProvider(provider),
    );
    _ctxAssembler = const MemoryContextAssembler(maxTokens: 3000);
    _leaveCoord = TransitionCoordinator(
      graph: const SceneGraph(scenes: {}, entrypoint: ''),
      settlement: const SettlementValidator(),
    );
    _ref = widget.packageRef ?? services?.defaultPackageRef();
    _saveId = widget.saveId;
    _sessionId = 'chat_${DateTime.now().millisecondsSinceEpoch}';

    final ref = _ref;
    final session = ref == null || services == null
        ? null
        : services.loadPlaySession(ref);
    if (session != null) {
      _session = session;
      _characterName = session.characterName;
      _systemPrompt = session.systemPrompt;
      // 新游戏：把包内**每个角色**的记忆树都先建出来（角色数 = characters/ 下的文件夹数），
      // 这样世界控制台能立刻列出全部记忆回廊入口。
      for (final c in session.content.characters) {
        _memories.treeOf(c.id);
      }
      // 新档的初始世界（注册表默认值 + 入口场景）：纯函数在 gal_protocol 里，
      // 读档则完全用存档自己的世界。
      if (widget.saveId == null) {
        _world = initialWorldFor(session.content);
      }
      _rebuildLeaveGraph();
    } else {
      _systemPrompt = genericSystemPrompt(_characterName);
    }
    // 事件表必须在**包加载之后**建：之前这里建得太早，`_session` 还是 null，
    // 于是真实事件永远没接上 —— 走到结局时事件层是空的，点一下直接抛
    // 「unknown event」，玩家卡在一张空白事件页上。
    _eventCoord = EventCoordinator(events: _session?.eventDefs ?? const {});
    _showBg = settings?.showBg ?? true;

    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final atBottom = _scroll.offset.abs() < 48;
      if (atBottom) {
        _followBottom = true;
      } else {
        _followBottom = false;
      }
    });

    if (widget.saveId != null && services != null) {
      final load = services.saves.load(widget.saveId!);
      final positionError = load.slot == null
          ? null
          : (session == null
                ? '当前内容包无法读取'
                : savePositionError(load.slot!, session.content));
      if (load.canEnter && load.slot != null && positionError == null) {
        final slot = load.slot!;
        _world = slot.world;
        _messages
          ..clear()
          ..addAll(slot.messageCheckpoint);
        _saveId = slot.saveId;
        _sessionId = slot.sessionId;
        _revision = slot.revision;
        _cursor = slot.runtimeCursor;
        _committedTransitions
          ..clear()
          ..addAll(slot.committedTransitions);
        _appliedSettlementIds
          ..clear()
          ..addAll(slot.appliedSettlementIds);
        if (slot.memoryCheckpoint.isNotEmpty) {
          // 存档不存阈值：用当前设置里的那套。
          _memories = MemoryBank.fromJson(
            slot.memoryCheckpoint,
            thresholds: _memoryThresholds,
          );
          _memories.applyThresholds(_memoryThresholds);
        }
        _unlockedEventIds
          ..clear()
          ..addAll(slot.pendingGalleryUnlocks);
        // 存档停在事件里（光标 mode=eventPlay）时要把事件层恢复出来：
        // `_eventPlay` 是界面状态、不落盘，不从这里重建的话，玩家杀掉进程再进来
        // 就看不到事件了 —— 而这次转场已经提交过，等于平白丢了一个结局。
        final eventId = _cursor.eventId;
        if (_cursor.mode == RuntimeCursor.modeEventPlay &&
            eventId != null &&
            _session?.eventDefs.containsKey(eventId) == true) {
          _eventPlay = EventPlayState(
            eventId: eventId,
            eventVisitId: _cursor.eventVisitId ?? 1,
            slideIndex: _cursor.slideIndex ?? 0,
            storyVisitId: _cursor.visitId,
          );
        }
        // 读档也要同步外观：否则 _clothing 为空 → 本轮不提交立绘表，
        // 而且表情会退回包声明之外的旧值。存下来的那张优先。
        _applyActors(_currentScene?.characters ?? const []);
        final storedExpr =
            '${(_world.presentation['appearance'] as Map?)?['expressionId'] ?? ''}';
        if (storedExpr.isNotEmpty) {
          // 存下来的那张优先：表情标签也要跟着回来，否则气泡上的情绪会退回
          // 场景声明值，看起来像"读档后表情变了"。
          _portraitRequest = storedExpr;
          _currentExpression = storedExpr;
        }
        // 读档同样只铺 L1：消息流是活跃窗口的镜像，历史原文留在存档里。
        _rebuildStreamFromWindow();
      } else {
        // 存档不可进入（版本/结构不支持、文件损坏…）。
        //
        // 以前这里什么都不做就继续初始化，接着 `_items.isEmpty` 分支会铺出起始场景
        // —— 看起来「正常开局」，其实玩家在玩一个**读不到的档**；之后再保存，
        // `_persistNow` 只检查 slot != null，会把当前状态写回并被 update() 写成
        // 当前 schema，等于把「不支持的存档」悄悄覆盖掉。
        // 现在：明确进入「不可玩」状态，不铺任何场景，并禁止任何写盘。
        _saveLocked = true;
        final lockReason = positionError ?? load.detail ?? load.reason.name;
        _saveLockedReason = lockReason;
        appLog.e('save', '存档不可进入（$lockReason）');
      }
    }

    if (_items.isEmpty && !_saveLocked && widget.saveId == null) {
      final scenes = _session?.content.scenes ?? const <String, SceneDef>{};
      if (scenes.isNotEmpty) {
        // 世界已经是 initialWorldFor() 的结果（注册表默认值 + 入口场景 +
        // 入场 fixedEffects），这里只负责把外观与开场卡片铺出来。
        final startScene = scenes['start'] ?? scenes.values.first;
        _applyActors(startScene.characters);
        _currentExpression = _currentExpression.isEmpty
            ? (_defaultEmotion.isEmpty ? '' : _defaultEmotion)
            : _currentExpression;
        _world = _world.copyWith(
          story: {
            ..._world.story,
            'nodeId': startScene.id,
            'storyId': startScene.id,
            'day': _world.variables['day'],
          },
          presentation: {
            ..._world.presentation,
            'scene': startScene.background,
            'narration': startScene.narration,
            'actors': startScene.characters.map((a) => a.toJson()).toList(),
            'appearance': {'expressionId': _currentExpression},
          },
        );
        _cursor = RuntimeCursor(
          mode: RuntimeCursor.modeStoryChat,
          storyId: startScene.id,
          visitId: 0,
        );
        final startTitle = '第$_day天 · ${startScene.displayName}';
        _items.add(
          _ChatItem.scene(startTitle, cleanChatText(startScene.narration)),
        );
      } else {
        _items.add(_ChatItem.system('第1天 · ${_usingMock ? 'Mock' : 'API'}'));
      }
    }

    // 读档时 L1 可能已被完整提炼。空消息窗口不等于新游戏，不能重置游标和世界。
    if (_items.isEmpty && !_saveLocked && widget.saveId != null) {
      final scene = _currentScene;
      if (scene != null) {
        _items.add(
          _ChatItem.scene(
            '第$_day天 · ${scene.displayName}',
            cleanChatText(scene.narration),
          ),
        );
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 锁档没有可玩进度：不启动自动恢复（那条路径会读/写 pending 并可能推进剧情）。
      if (!_saveLocked) unawaited(_resumeSavedPresentation());
      // 新档（含第一天）进场：先播一次时段过场，再让对方开口；读档不重放。
      if (widget.saveId == null && !_saveLocked) {
        unawaited(_enterSceneOpening());
      }
    });
  }

  /// 换场/开场的统一顺序：换幕过场 → 解锁 → 请角色先开口。
  ///
  /// 这里必须**自己**管住 `_busy`：过场期间不接受输入，也不接受再次切换；
  /// 过场结束先解锁再调 [_generateOpening]（后者开头会检查 `_busy`，
  /// 之前就是因为 `_advanceTime` 的 finally 还没跑就调它，导致换场后
  /// 开场白永远被自己挡掉、角色不会先说话）。
  Future<void> _enterSceneOpening() async {
    if (!mounted) return;
    setState(() => _busy = true);
    await _playPeriodTransition(
      dayAfter: _day,
      sceneName: _currentScene?.displayName ?? _sceneId,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    unawaited(_generateOpening());
  }

  /// 与转场一起落盘，进程在「已保存、尚未开口」之间退出也能恢复。
  void _markOpeningPending() {
    _world = _world.copyWith(
      presentation: {
        ..._world.presentation,
        'pendingOpening': {'storyId': _sceneId, 'visitId': _cursor.visitId},
      },
    );
  }

  bool get _openingPending {
    final marker = _world.presentation['pendingOpening'];
    return marker is Map &&
        marker['storyId'] == _sceneId &&
        marker['visitId'] == _cursor.visitId &&
        _cursor.mode == RuntimeCursor.modeStoryChat;
  }

  Future<void> _resumeSavedPresentation() async {
    await _recoverPendingAfterLoad();
    if (!mounted ||
        _busy ||
        _streaming ||
        _hasUnsavedFailure ||
        _hasPendingAfterSave ||
        !_openingPending) {
      return;
    }
    await _enterSceneOpening();
  }

  /// 全屏换幕过场。
  ///
  /// **触发规则由包决定**：要进入的这一幕声明了 `atmosphere`（转场气氛）才播；
  /// 没有就静默切换 —— 所以「同一时段内的换幕」也会播，只要那一幕写了气氛句。
  /// （以前是「天数变了才播」，于是只有跨天那一次能看到过场。）
  ///
  /// 显示的天数是**已经算完入场改值**的天数（[dayAfter] 传的就是 `_day`），
  /// 所以「新一天第一幕 +1」那一幕的过场会直接显示新的天数。
  ///
  /// 背景用**要进入那一幕的聊天背景**（这一层后面本来就是同一张图，画上来之后
  /// 过场淡出 = 落进这一幕，画面是连续的）；那一幕没有背景图、或设置里关掉了
  /// 「显示场景背景」时退回纯色薄纱。
  Future<void> _playPeriodTransition({
    required int dayAfter,
    required String sceneName,
  }) async {
    if (!mounted) return;
    final atmosphere = (_currentScene?.atmosphere ?? '').trim();
    if (atmosphere.isEmpty) return;
    // 重入保护：再进来一次会把 `_periodDone` 换掉，上一个 await 就永远挂着。
    // 调用侧现在由 `_busy` 兜着，但这条不变量不该靠调用方自觉。
    final running = _periodDone;
    if (running != null && !running.isCompleted) return;
    final done = Completer<void>();
    final background = _periodBackgroundPath();
    setState(() {
      _periodSerial += 1;
      _periodAnim = _PeriodAnim(
        day: dayAfter,
        sceneName: sceneName,
        atmosphere: atmosphere,
        backgroundPath: background,
        serial: _periodSerial,
      );
      _periodDone = done;
    });
    await done.future;
  }

  /// 过场要用的背景图（要进入那一幕的），拿不到就返回 null。
  String? _periodBackgroundPath() {
    if (!_showBg) return null;
    final session = _session;
    if (session == null) return null;
    final scene = '${_world.presentation['scene'] ?? ''}';
    if (scene.isEmpty) return null;
    return session.sceneBackgroundPath(scene);
  }

  void _finishPeriodTransition() {
    final done = _periodDone;
    _periodDone = null;
    if (mounted) {
      setState(() => _periodAnim = null);
    } else {
      _periodAnim = null;
    }
    if (done != null && !done.isCompleted) done.complete();
  }

  /// Clear residual pending after first frame (S1 crash recovery).
  Future<void> _recoverPendingAfterLoad() async {
    if (_saveLocked) return;
    final services = widget.services;
    final saveId = _saveId;
    if (services == null || saveId == null) return;
    final loaded = services.saves.load(saveId);
    final slot = loaded.slot;
    final pending = slot?.pending;
    if (slot == null || pending == null) return;

    // Already committed → never roll back; only clear the residual.
    if (_committedTransitions.contains(pending.id)) {
      await _persist(clearPending: true);
      return;
    }

    // Uncommitted draft on the same revision → **re-run** the leave. The
    // deterministic transition/settlement ids make this safe: nothing is
    // counted twice, and the scene change completes instead of being lost.
    if (pending.baseRevision == _revision) {
      await _advanceTime();
      return;
    }

    // Stale draft → drop it, keep the current scene, tell the player.
    await _persist(clearPending: true);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('上次切换未完成，已保留原场景')));
    }
  }

  /// 离场事务用的就是包自己的场景图。v2 包一定有 scenes（loader 强制
  /// `stories/*.json`），所以「没有场景时从旧节点投影出图」的那条支路已删。
  void _rebuildLeaveGraph() {
    final session = _session;
    final graph = session?.sceneGraph;
    if (graph == null || graph.scenes.isEmpty) return;
    _leaveCoord = TransitionCoordinator(
      graph: graph,
      registry: session?.content.variableRegistry ?? VariableRegistry.empty,
      memory: _memoryRt,
    );
  }

  @override
  void dispose() {
    _coord.cancel(_sessionId);
    // 立绘 agent 的独立请求也要一起作废：否则退出后迟到的结果仍会
    // setState / 记记忆 / 消耗额度（复审 P1：页面销毁后 agent 回调）。
    _replyEpoch++;
    final look = _lookCancel;
    _lookCancel = null;
    look?.cancel();
    _memoryEpoch++;
    _streamTimer?.cancel();
    // 过场动画没跑完就离开页面时，等它的那个 await 会永远挂着：这里主动收尾。
    final playback = _textPlaybackDone;
    _textPlaybackDone = null;
    if (playback != null && !playback.isCompleted) playback.complete();
    final pending = _periodDone;
    _periodDone = null;
    _periodAnim = null;
    if (pending != null && !pending.isCompleted) pending.complete();
    // 离开页面必须停朗读：不然原生播放器会继续念，
    // 而且 _tts 自己是 ChangeNotifier，监听也要摘掉。
    final tts = _tts;
    _tts = null;
    if (tts != null) {
      tts.removeListener(_onTtsChanged);
      tts.dispose();
    }
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    _leaveTick?.cancel();
    super.dispose();
  }

  Future<void> _confirmBack() async {
    // 不可进入的存档：没有可保存的东西，直接离开（不弹确认、不写盘）。
    // 交回 null = 「这次没有玩到任何档」——不要把主页重新钉在这份打不开的档上。
    if (_saveLocked) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final t = widget.theme;
    Future<bool?> ask({
      required String title,
      required String message,
      required String cancelText,
      required String okText,
      bool danger = false,
    }) {
      return showDialog<bool>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            width: 300,
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            decoration: BoxDecoration(
              color: t.card,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: danger
                        ? Colors.redAccent.withValues(alpha: 0.12)
                        : t.accent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    danger ? Icons.warning_amber_rounded : Icons.logout_rounded,
                    color: danger ? Colors.redAccent : t.accent,
                    size: 26,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: t.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: t.sub, height: 1.45),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: BorderSide(
                            color: t.sub.withValues(alpha: 0.35),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(cancelText, style: TextStyle(color: t.sub)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: FilledButton.styleFrom(
                          backgroundColor: danger ? Colors.redAccent : t.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(okText),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_busy || _streaming || _replyInFlight) {
      final leave = await ask(
        title: '正在回复中',
        message: '离开可能丢失未保存进度，确定返回吗？',
        cancelText: '继续游戏',
        okText: '返回',
        danger: true,
      );
      if (leave == true && mounted) Navigator.of(context).pop(_saveId);
      return;
    }
    final ok = await ask(
      title: '返回主页',
      message: '进度会自动保存，确定要离开吗？',
      cancelText: '取消',
      okText: '确定返回',
    );
    if (ok == true && mounted) {
      await _persist();
      // 保存失败就不静默离开：留在页面让玩家重试（与换幕/事件出口同一条规则）。
      // 但也不能把人锁死在游戏里 —— 明确给一个「仍然离开」的出口。
      if (_hasUnsavedFailure) {
        final leaveAnyway = await ask(
          title: '保存失败',
          message:
              '$_lastPersistError\n\n现在离开会丢掉这一段进度'
              '${_hasPendingAfterSave ? '，并且这一幕的开场还没播' : ''}。确定要离开吗？',
          cancelText: '留在这里',
          okText: '仍然离开',
          danger: true,
        );
        if (leaveAnyway != true || !mounted) return;
        // 玩家明确要离开：挂起的动作作废（人都不在游戏里了）。
        _pendingAfterSave = null;
        appLog.w('chat', '玩家在保存失败后选择仍然离开（不伪装成保存成功）');
        await _popToHome(force: true);
        return;
      }
      if (mounted) await _popToHome();
    }
  }

  void _scrollToBottom({bool force = false}) {
    if (!_scroll.hasClients) return;
    if (!force && !_followBottom) return;
    if (_scroll.offset.abs() < 1 && !force) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _scrollByLine() {
    if (!_scroll.hasClients || !_followBottom) return;
    if (_scroll.offset <= 0) return;
    final delta = math.min(_scroll.offset, 28.0);
    _scroll.animateTo(
      _scroll.offset - delta,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutQuad,
    );
  }

  /// 切换当前外观：立绘优先用模型选的那张，没有就按情绪词解析。
  void _applyLook(String emotion, String portrait) {
    if (emotion.isNotEmpty) _currentExpression = emotion;
    _portraitRequest = portrait.isNotEmpty ? portrait : _currentExpression;
  }

  /// 聊天气泡用的字体/字号（设置 → 外观 → 字体与字号）。
  /// 只给对话气泡用 —— 界面本身、系统提示卡都不变。
  TextStyle _chatStyle(Color color) => chatTextStyle(
    fontId: _chatFontId,
    imported: _importedFonts,
    fontSize: _chatFontSize,
    color: color,
  );

  void _onTtsChanged() {
    if (!mounted) return;
    final err = _tts?.lastError;
    if (err != null && err != _reportedTtsError) {
      _reportedTtsError = err;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('朗读失败：$err')));
      _tts?.clearError();
    }
    setState(() {});
  }

  String? _reportedTtsError;

  /// 朗读一条气泡（原样保留括号描写由 TtsSettings.skipActions 决定）。
  Future<void> _speakBubble(_ChatItem item) async {
    final tts = _tts;
    if (tts == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('语音朗读未开启，请到「设置 → 语音配置」打开')));
      return;
    }
    final text = ttsSpeakableText(
      item.text,
      skipActions: _ttsSettings.skipActions,
    );
    if (text.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('这一条只有动作描写，没有可朗读的台词')));
      return;
    }
    appLog.i('tts', '朗读气泡（${text.length} 字）');
    _speakingToken = item;
    setState(() {});
    await tts.speak(text, interrupt: true);
    if (!mounted) return;
    if (_speakingToken == item) {
      setState(() => _speakingToken = null);
    }
  }

  Future<void> _stopSpeaking() async {
    final tts = _tts;
    if (tts == null) return;
    appLog.d('tts', '停止朗读');
    await tts.stop();
    if (!mounted) return;
    setState(() => _speakingToken = null);
  }

  /// 自动朗读：整条回复落地之后，按段依次读出来。
  Future<void> _maybeAutoRead(List<String> segmentTexts, Object? token) async {
    final tts = _tts;
    if (tts == null || !_ttsSettings.autoRead) return;
    final usable = [
      for (final s in segmentTexts)
        if (ttsSpeakableText(
          s,
          skipActions: _ttsSettings.skipActions,
        ).isNotEmpty)
          ttsSpeakableText(s, skipActions: _ttsSettings.skipActions),
    ];
    if (usable.isEmpty) return;
    _speakingToken = token;
    if (mounted) setState(() {});
    appLog.i('tts', '自动朗读 ${usable.length} 段');
    await tts.speakAll(usable);
    if (!mounted) return;
    if (_speakingToken == token) setState(() => _speakingToken = null);
  }

  /// 逐段播放：文字推进时跨过分段边界就换立绘 —— 一次回复里的多表情靠这个
  /// 才看得见（原来只按最后一段定一张，整条回复期间立绘是死的）。
  void _runTypewriter(
    String full,
    void Function(String partial) onTick,
    void Function() onDone, {
    List<({int len, String emotion, String portrait})> bounds = const [],
  }) {
    final marks = <({int at, String emotion, String portrait})>[];
    var at = 0;
    for (final b in bounds) {
      marks.add((at: at, emotion: b.emotion, portrait: b.portrait));
      at += b.len;
    }
    var applied = -1;

    _streamTimer?.cancel();
    _streaming = true;
    var i = 0;
    _streamTimer = Timer.periodic(const Duration(milliseconds: 32), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final prevLines = _lastLineCount(_streamText);
      i = math.min(i + 2, full.length);
      _streamText = full.substring(0, i);
      if (marks.isNotEmpty) {
        var pick = 0;
        for (var m = 0; m < marks.length; m++) {
          if (marks[m].at < i) pick = m;
        }
        if (pick != applied) {
          applied = pick;
          _applyLook(marks[pick].emotion, marks[pick].portrait);
        }
      }
      final newLines = _lastLineCount(_streamText);
      onTick(_streamText);
      if (_followBottom) {
        if (newLines > prevLines) {
          _scrollByLine();
        } else {
          _scrollToBottom();
        }
      }
      if (i >= full.length) {
        t.cancel();
        _streaming = false;
        onDone();
      }
    });
  }

  int _lastLineCount(String s) => '\n'.allMatches(s).length + 1;

  /// 光标是「当前运行位」的权威：改它的时候要同步进 world.presentation，
  /// 否则存档里的光标与内存里的会分叉（事件层恢复就会指错地方）。
  void _setCursor(RuntimeCursor next) {
    _cursor = next;
    _world = _world.copyWith(
      presentation: {..._world.presentation, 'cursor': next.toJson()},
    );
  }

  /// 事件层当前该停在哪一格（进入事件 / 点幻灯片都用它推进光标）。
  void _setEventPlay(EventPlayState? play) {
    _eventPlay = play;
    if (play == null) return;
    // 事件翻页只改事件进度，必须保留剧情访问号：写死 visitId: 0 会让
    // 事件返回剧情后再 visitId+1 从 1 开始，撞上既有结算 ID 被静默跳过。
    _setCursor(
      RuntimeCursor(
        mode: RuntimeCursor.modeEventPlay,
        storyId: null,
        visitId: play.storyVisitId,
        eventId: play.eventId,
        slideIndex: play.slideIndex,
        eventVisitId: play.eventVisitId,
      ),
    );
  }

  /// 换场等待开始了：挂上状态卡并开始数秒。
  void _beginLeaveStatus() {
    _leaveTick?.cancel();
    setState(() {
      _leaveStatus = const LeaveStatus();
    });
    _leaveTick = Timer.periodic(const Duration(seconds: 1), (_) {
      final s = _leaveStatus;
      if (!mounted || s == null) return;
      setState(() => _leaveStatus = s.copyWith(seconds: s.seconds + 1));
    });
  }

  /// 协调器每推进一步回调一次：记忆（每个角色）→ 结算 → 完成。
  void _onLeaveProgress(LeavePhase phase, int done, int total, String? owner) {
    final s = _leaveStatus;
    if (!mounted || s == null) return;
    setState(() {
      // owner 为 null 时保留上一位（copyWith 的 `?? this.owner`）：界面不会闪回无名。
      _leaveStatus = s.copyWith(
        phase: phase,
        done: done,
        total: total,
        owner: owner,
      );
    });
  }

  void _endLeaveStatus() {
    _leaveTick?.cancel();
    _leaveTick = null;
    if (_leaveStatus == null) return;
    setState(() => _leaveStatus = null);
  }

  Future<void> _advanceTime() async {
    // Double-click: second call rejected while busy (S1 N2 queue).
    if (_busy || _streaming || _replyInFlight) {
      return;
    }
    // 上一次保存失败 / 还有挂起的入场动作：阻止推进，先让玩家走同一个恢复入口。
    if (_blockedBySaveFailure()) return;
    if (_session == null || _session!.content.scenes.isEmpty) return;
    // 换幕期间输入框是禁用的：把键盘收起来，别让它盖着过场动画。
    _inputFocus.unfocus();
    setState(() => _busy = true);
    // 后台高层整理不阻塞换幕；迟到的旧结果必须作废。
    _memoryEpoch++;
    var startOpening = false;
    // 先让光标指向当前幕（leaveCurrent 会用 `cursor.storyId ?? story['storyId']`
    // 推出 fromStoryId），再算 pending id —— 两处必须**逐字一致**，
    // 否则 `_recoverPendingAfterLoad` 里「已提交 → 只清残骸」那条分支永远不命中。
    final nodeId = '${_world.story['nodeId'] ?? ''}';
    if (nodeId.isNotEmpty) {
      _cursor = _cursor.copyWith(
        mode: RuntimeCursor.modeStoryChat,
        storyId: nodeId,
        visitId: _cursor.storyId == nodeId ? _cursor.visitId : 0,
      );
    }
    final fromStoryId = _cursor.storyId ?? '${_world.story['storyId'] ?? ''}';
    final pendingId = TransitionCoordinator.transitionIdFor(
      sessionId: _sessionId,
      baseRevision: _revision,
      fromStoryId: fromStoryId,
      fromVisitId: _cursor.visitId,
    );
    try {
      // Write pending before draft work (kind=storyTransition).
      await _writePending(
        PendingOp(
          kind: PendingOp.kindStoryTransition,
          id: pendingId,
          baseRevision: _revision,
          phase: 'drafting',
          cache: {
            'fromStoryId': fromStoryId,
            'fromVisitId': _cursor.visitId,
            'inputHash': '${_messages.length}',
            'rulesVersion': 's1',
          },
        ),
      );

      if (_lastPersistError != null || !mounted) return;

      // 这一段要等模型：本幕记忆提炼（每个在场角色一次）→ 离场结算（一次）。
      _beginLeaveStatus();
      final leave = await _leaveCoord.leaveCurrent(
        sessionId: _sessionId,
        world: _world,
        messages: _messages,
        baseRevision: _revision,
        provider: _settlementProvider(),
        committedTransitions: _committedTransitions,
        appliedSettlementIds: _appliedSettlementIds,
        bank: _memories,
        cursor: _cursor,
        onProgress: _onLeaveProgress,
      );
      if (!mounted) return;

      // 记忆提炼没拿到模型摘要时，L2 记的是原文拼接。这件事以前只写进
      // dart:developer 的日志（release 包里压根看不到），玩家只会觉得
      // 「记忆怎么突然变成一大段原话」。这里如实告诉玩家，并进应用日志。
      if (leave.memoryNotes.isNotEmpty) {
        appLog.w('memory', '换场记忆兜底：${leave.memoryNotes.join('；')}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(leave.memoryNotes.first)),
        );
      }

      if (leave.noExit) {
        // 本情景没有出口（没写 target，或没有任何块的 require 成立）：这不是
        // 错误 —— 清掉 pending、留在原情景，玩家可以继续和她说话。
        await _writePending(null);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('暂时不能进入下一阶段噢')));
        }
        return;
      }

      if (!leave.accepted) {
        await _writePending(null);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('进入下一阶段失败：${leave.error ?? '未知错误'}')),
          );
        }
        return;
      }

      // Merge leave result into app state.
      var world = leave.world!;
      _world = world;
      _messages
        ..clear()
        ..addAll(leave.messages);
      _revision = leave.revision;
      _cursor = leave.cursor ?? _cursor;
      _committedTransitions.add(leave.transitionId!);
      _appliedSettlementIds.addAll(leave.appliedSettlementIds);
      // The leave transaction returns the memory bank it summarized into.
      // 内容就地覆盖（不换引用）：界面可能正持有这个 bank 实例。
      final leaveMemories = leave.memories;
      if (leaveMemories != null) _memories.replaceWith(leaveMemories);

      if (leave.targetKind == 'event' && leave.nextEventId != null) {
        setState(() {
          _items.add(_ChatItem.scene('事件', '进入事件：${leave.nextEventId}'));
          // 光标已经由 leave 事务写成 eventPlay（含累计访问号），这里只跟它对齐。
          // storyVisitId = 进入事件前的剧情访问号，收尾回剧情时要接着数。
          _eventPlay = EventPlayState(
            eventId: leave.nextEventId!,
            eventVisitId: leave.cursor?.eventVisitId ?? 1,
            slideIndex: 0,
            storyVisitId: leave.cursor?.visitId ?? 0,
          );
        });
        _followBottom = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
        await _persist(clearPending: true);
        return;
      }

      if (leave.targetKind == 'appShell') {
        setState(() {
          _items.add(_ChatItem.system('已返回主页（appShell）'));
        });
        await _persist(clearPending: true);
        // 保存失败时不弹回主页：留在页面让玩家重试，避免进度丢失。
        // 重试走**同一个恢复入口**（有挂起动作时会先补做再继续），
        // 不能只 `_persist()` —— 那样保存成功就把「该回主页」这件事吞掉了。
        if (_hasUnsavedFailure) {
          _blockAndOfferRetry(() async {
            if (!mounted) return;
            _popToHome();
          });
          return;
        }
        // 出口是「回主页」就真的回去：只加个气泡会让玩家滞留在聊天页。
        // 必须绕过 PopScope 的确认流程（_allowSystemPop）。
        if (!mounted) return;
        _popToHome();
        return;
      }

      final nextId = leave.nextSceneId ?? '';
      final nextScene = _session?.content.scenes[nextId];
      // 换幕的外观与背景只来自场景声明（v2 场景自带 background 文件名）
      if (nextScene != null) {
        _applyActors(nextScene.characters);
        // 换幕必须清掉上一幕选中的立绘名：它带着旧 state（服装/形态），
        // 候选链第一项会精确命中旧 state 的图 —— 表现就是「换了衣服却穿帮」。
        _portraitRequest = _currentExpression;
      }
      final story = Map<String, Object?>.from(world.story)
        ..['nodeId'] = nextId
        ..['day'] = world.variables['day'] ?? _day;
      world = world.copyWith(
        story: story,
        presentation: {
          ...world.presentation,
          'scene': nextScene?.background ?? world.presentation['scene'],
          'appearance': {'expressionId': _currentExpression},
        },
      );
      _world = world;

      // 换幕：消息流整体重建（= 新一轮的 L1 镜像），旧幕的对话不再铺在屏幕上
      _rebuildStreamFromWindow();
      _markOpeningPending();
      await _persist(clearPending: true);
      // 保存失败时不要继续播开场白：进度没落盘，继续推进会丢数据。
      // 重试走同一个恢复入口，保存成功后再把这一幕的过场 + 开场白补上
      // （以前这里只重存一遍，开场白就此漏播）。
      if (_hasUnsavedFailure) {
        _blockAndOfferRetry(_enterSceneOpening);
        return;
      }
      startOpening = true;
    } catch (e) {
      await _writePending(null);
      // 换幕事务失败要留证据：这类异常以前只在屏幕上闪一下，日志里什么都没有。
      appLog.e('transition', '换幕推进异常', e);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('推进异常：$e')));
      }
    } finally {
      _endLeaveStatus();
      if (mounted) setState(() => _busy = false);
      if (mounted) unawaited(_consolidateThenPersist());
    }
    // 换场成功：先播换幕过场，再让角色先开口（必须在 finally 之后 —— 上面
    // 那句 setState 之前 `_busy` 还是 true，会把开场白挡掉）。
    if (startOpening && mounted) {
      await _enterSceneOpening();
    }
  }

  Future<void> _writePending(PendingOp? pending) async {
    final services = widget.services;
    final saveId = _saveId;
    if (services == null || saveId == null) return;
    // 不可进入的存档同样不写（换幕 pending 也是写盘）。
    if (_saveLocked) return;
    // 也走串行队列：绕过队列直接写会与 _persist 并发覆盖同一个 .tmp 文件。
    final next = _persistQueue
        .then((_) async {
          final loaded = services.saves.load(saveId);
          final slot = loaded.slot;
          if (slot == null) throw StateError('存档无法读取，未写入换幕记录');
          await services.saves.update(
            slot,
            world: _world,
            messages: _messages,
            revision: _revision,
            runtimeCursor: _cursor,
            committedTransitions: _committedTransitions,
            pending: pending,
            clearPending: pending == null,
          );
          _lastPersistError = null;
        })
        .catchError((Object e) {
          _lastPersistError = '$e';
          debugPrint('[writePending] 保存失败：$e');
          appLog.e('save', '换幕 pending 记录写入失败', e);
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('保存失败，已停止推进：$e')));
          }
        });
    _persistQueue = next;
    await next;
  }

  /// The character this session speaks as (memory owner).
  /// 以当前幕出场角色为准；空角色幕退回包内第一个角色。
  String get _owner {
    final char = _currentCharacter;
    return char?.id ?? '';
  }

  /// This character's memory tree.
  CharacterMemoryTree get _charMemory => _memories.treeOf(_owner);

  /// Characters present in the current scene — the audience of a round.
  List<String> get _sceneAudience {
    final scene = _currentScene;
    if (scene == null) return [_owner];
    final ids = <String>[
      for (final c in scene.characters)
        if (c.charId.isNotEmpty) c.charId,
    ];
    return ids.isEmpty ? [_owner] : ids;
  }

  Map<String, Object?> _memoryFacts() => {'day': _day, 'scene': _sceneId};

  /// 正文完成时先同步记入 L1，下一句立刻能拿到完整上下文。
  /// 保存与记忆整理后台串行进行，不让摘要请求挡住玩家接话。
  Future<void> _recordTurn(String userText, String replyText) async {
    if (_openingPending) {
      final presentation = Map<String, Object?>.from(_world.presentation)
        ..remove('pendingOpening');
      _world = _world.copyWith(presentation: presentation);
    }
    final audience = _sceneAudience;
    var turnId = '';
    for (var i = _messages.length - 1; i >= 0; i--) {
      final id = '${_messages[i]['turnId'] ?? ''}';
      if (id.isNotEmpty) {
        turnId = id;
        break;
      }
    }
    if (turnId.isEmpty) {
      turnId = 'turn_${_revision}_${DateTime.now().microsecondsSinceEpoch}';
    }
    _memories.recordTurn(
      DialogueTurn(
        turnId: turnId,
        playerText: userText,
        replyText: replyText,
        audience: audience,
        storyId: _sceneId,
        visitId: _cursor.visitId,
        at: DateTime.now(),
      ),
    );
    _rebuildStreamFromWindow();
    // 先将原文排入保存队列；整理失败也不能丢掉已完成的对白。
    unawaited(_finishTurnMemory(audience, _memoryFacts(), _memoryEpoch));
  }

  Future<void> _finishTurnMemory(
    List<String> audience,
    Map<String, Object?> facts,
    int epoch,
  ) async {
    try {
      await _persist();
      if (!mounted ||
          epoch != _memoryEpoch ||
          _hasUnsavedFailure ||
          _memoryBusy) {
        return;
      }
      _memoryBusy = true;
      try {
        var changed = false;
        for (final owner in audience) {
          final plan = await _memoryRt.planThresholdCollapse(
            bank: _memories,
            owner: owner,
            facts: facts,
          );
          if (!mounted || epoch != _memoryEpoch) return;
          if (plan != null) {
            changed = _memoryRt.commitCollapse(_memories, plan) || changed;
          }
        }
        if (changed) await _persist();
        // 下一轮可能正在流式输出；旧整理不得清空新气泡或改变其索引。
        if (changed && mounted && epoch == _memoryEpoch && !_replyInFlight) {
          _rebuildStreamFromWindow();
        }
      } finally {
        _memoryBusy = false;
      }
      if (mounted && epoch == _memoryEpoch) {
        unawaited(_consolidateThenPersist());
      }
    } catch (e) {
      appLog.w('memory', '回复已记录，后台整理未完成：$e');
    }
  }

  /// 消息流 = **L1 活跃窗口的镜像**：换场景后整屏清空、记忆坍缩后顶部跟着变短、
  /// 上限就是活跃窗口的容量。历史原文仍在存档里，只是不再铺在屏幕上。
  void _rebuildStreamFromWindow() {
    if (!mounted) return;
    final scene = _currentScene;
    final items = <_ChatItem>[];
    if (scene != null) {
      items.add(
        _ChatItem.scene(
          '第$_day天 · ${scene.displayName}',
          cleanChatText(scene.narration),
        ),
      );
    }
    for (final t in _memories.windowOf(_owner).turns) {
      if (t.playerText.trim().isNotEmpty) {
        items.add(_ChatItem.user(t.playerText));
      }
      if (t.replyText.trim().isNotEmpty) {
        items.add(_ChatItem.jj(t.replyText));
      }
    }
    // 投影出来的消息若与旧列表里某一条是同一条（kind + 正文一致），沿用**旧对象**：
    // id 与对象身份都不变，正在播的入场动画不会因为元素被重建而中断，
    // 朗读令牌那种 identical 判定也不会失效。旧列表下标单调前进，
    // 多出来的气泡（系统提示、事件卡）自然被跳过。
    var cursor = 0;
    for (var i = 0; i < items.length; i++) {
      while (cursor < _items.length && !_sameMessage(_items[cursor], items[i])) {
        cursor++;
      }
      if (cursor < _items.length) {
        items[i] = _items[cursor];
        cursor++;
      }
    }
    setState(() {
      _items
        ..clear()
        ..addAll(items);
      // 只留还活着的气泡 id：调出窗口的消息不会再回来，留着只会让集合无上限增长。
      final alive = {for (final it in items) it.id};
      _bubbleEntered.removeWhere((id) => !alive.contains(id));
    });
    _followBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  /// 两条气泡是不是同一条消息（重建消息流时用来决定能否沿用旧对象）。
  static bool _sameMessage(_ChatItem a, _ChatItem b) =>
      a.kind == b.kind && a.text == b.text;

  /// 已触发的事件：只认这份存档自己的台账（**不再靠 endingId 反推**——
  /// 那是给早期没有台账的存档兜底的旧档兼容，现在已删除）。
  Set<String> _triggeredEventIds() {
    final out = <String>{..._unlockedEventIds};
    for (final id in _world.eventHistory.keys) {
      out.add(id);
    }
    return out;
  }

  /// Real settlement when a model is configured; deterministic mock otherwise.
  SettlementProvider _settlementProvider() {
    final services = widget.services;
    if (services == null || !services.api.isConfigured) {
      return const ChatMockSettlement();
    }
    return DialogueSettlementProvider(services.api.createProvider());
  }

  /// L2→L3→L4→L5, deliberately decoupled from scene changes so switching
  /// scenes does not have to wait for it.
  ///
  /// 高层整理保留后台执行，但增加**单任务控制**：已有整理在跑就跳过本轮
  /// （不让两次整理在同一份记忆上并行等模型，然后各自提交产生重复 ID）。
  Future<void> _consolidateThenPersist() async {
    if (_memoryBusy) return;
    _memoryBusy = true;
    final epoch = _memoryEpoch;
    try {
      var changed = false;
      for (final owner in _memories.owners.toList()) {
        if (!mounted || epoch != _memoryEpoch) return;
        if (await _memoryRt.consolidate(
          _memories,
          owner,
          isCurrent: () => mounted && epoch == _memoryEpoch,
        )) {
          changed = true;
        }
      }
      if (changed && mounted && epoch == _memoryEpoch) await _persist();
    } finally {
      _memoryBusy = false;
    }
  }

  String get _sceneId {
    final fromStory = '${_world.story['nodeId'] ?? ''}';
    if (fromStory.isNotEmpty) return fromStory;
    final fromStoryId = '${_world.story['storyId'] ?? ''}';
    if (fromStoryId.isNotEmpty) return fromStoryId;
    return _cursor.storyId ?? 'start';
  }

  SceneDef? get _currentScene {
    final s = _session?.content.scenes[_sceneId];
    if (s != null) return s;
    final entry = _session?.sceneGraph?.entrypoint;
    if (entry != null) return _session?.content.scenes[entry];
    return null;
  }

  String get _topTitle {
    final scene = _currentScene;
    final name = scene?.displayName ?? _sceneId;
    return '第${_day}天 · $name';
  }

  List<Map<String, String>> _buildChatMessages(String userText) {
    final facts = _authorityFacts();
    // 角色基础人格按**当前幕出场角色**取；协议壳由 systemPromptFor 固定拼上。
    // 回复长度约束（回复长度是全局设置，不再由游戏内调）。
    final base =
        '${_session?.systemPromptFor(_owner) ?? _systemPrompt}\n'
        '${replyLengthHint(_replyLength)}';
    // Author design: scene prompt lives only on the character block.
    final charScene = _session?.scenePromptFor(_sceneId, _owner) ?? '';
    // 注意：不要在这里追加本轮玩家输入 —— 协调器统一负责追加，
    // 否则（本轮修复前）用户那句话会被发两遍。
    return _ctxAssembler.assemble(
      protocolShell: '',
      basePrompt: base,
      scenePrompt: '',
      characterScenePrompt: charScene,
      // 世界事实后面补一句硬约束：关系语言必须与实际数值一致。
      // 否则 scenePrompt 里按天数写死的「唯一依靠」等态度文本，
      // 会在好感/信任很低时仍然输出，造成人设与数值脱节。
      authorityFacts:
          '${facts}\n'
          '（关系语气必须与上面的数值一致：好感/信任低时不要表现得亲密依赖，'
          '高时才可以亲近；不要被场景提示词里的固定态度带偏）',
      tree: _charMemory,
      activeTurns: _memories.windowIfExists(_owner)?.turns ?? const [],
      // 不再给聊天词表：选立绘只归立绘 agent（§32）。genericSystemPrompt
      // 已要求不要输出 JSON；再塞【可用立绘】等于逼它去选图。
      messages: _messages,
      currentUserInput: userText,
    );
  }

  /// 从本幕角色块同步外观：状态（服装×形态）与默认表情。
  /// 多角色时只取自己那一份；场景没写自己就保持原样。
  void _applyActors(List<SceneActor> actors) {
    for (final c in actors) {
      if (c.charId != _owner) continue;
      final state = c.state ?? '';
      final emotion = c.emotion ?? '';
      if (state.isNotEmpty) _clothing = state;
      if (emotion.isNotEmpty) {
        _currentExpression = emotion;
        _portraitRequest = emotion;
      }
      return;
    }
  }

  /// 存档写入串行化：回复、自动坍缩、后台整理都可能触发保存，
  /// 同时写同一个文件会互相覆盖（temp+rename 只保证单次写是原子的）。
  Future<void> _persistQueue = Future<void>.value();

  /// 量一次底部整块（立绘 + 输入栏）的高度，用于消息流的底部留白。
  /// 每帧最多排一次；高度没变就不 setState，避免无谓重建。
  void _scheduleBottomMeasure() {
    if (_bottomMeasureScheduled) return;
    _bottomMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bottomMeasureScheduled = false;
      if (!mounted) return;
      final box =
          _bottomBlockKey.currentContext?.findRenderObject() as RenderBox?;
      final h = box?.size.height ?? 0;
      if (h <= 0) return;
      // 顺手把「输入栏」的高度发布出去：设置页的预览窗用它当真值，
      // 这样「预览里的留白」和「进游戏看到的留白」不再是两套数。
      final bar = h - ChatLayout.portrait(_portraitHeight);
      if (bar > 0 &&
          (bar - ChatLayout.measuredInputBarHeight.value).abs() > 0.5) {
        ChatLayout.measuredInputBarHeight.value = bar;
      }
      if ((h - _bottomBlockHeight).abs() < 0.5) return;
      setState(() => _bottomBlockHeight = h);
    });
  }

  /// 存档不可进入（版本/结构不支持、文件损坏…）。
  ///
  /// 这时**不能**继续初始化成「像是新开局」——否则玩家在玩一个读不到的档，
  /// 保存还会把当前状态写回、由 update() 写成当前 schema，把原档悄悄覆盖掉。
  bool _saveLocked = false;
  String _saveLockedReason = '';

  /// 最近一次保存失败的错误信息；成功保存后清空。
  /// 调用方（换幕、离开页面）应检查它，失败时提示用户并阻止「假装已保存」。
  String? _lastPersistError;

  /// 保存代次：每次 _persist 入队时 +1。
  /// 成功时只在「当前代次仍是自己」时清错误——避免「A 成功清掉 B 的失败」。
  int _persistGen = 0;

  /// 最后一次完整保存成功的代次。
  int _lastPersistedGen = 0;

  /// 有内存状态变更但尚未确认落盘。
  /// 在 _persist 入队时置 true，在对应代次成功后置 false。
  /// 离开页面 / 换幕前检查：true 且 _lastPersistError != null 时阻止推进。
  bool get _uncommitted => _persistGen > _lastPersistedGen;

  /// 关键路径（换幕、离开）前：有未提交变更且上次保存失败时返回 true。
  bool get _hasUnsavedFailure => _uncommitted && _lastPersistError != null;

  /// 落盘失败时挂起的「保存后动作」。
  ///
  /// 事件出口（回剧情 / 弹回主页）以前只 `await _persist()` 就继续往下走：
  /// 普通换幕那条路已经会挡住（`_hasUnsavedFailure`），事件这条路没有 —— 于是
  /// 保存失败照样播过场、照样请求开场白，产出一段没落盘的对话与记忆。
  /// 现在把动作挂起来，重试保存成功后再执行一次，既不漏播也不重播。
  Future<void> Function()? _pendingAfterSave;

  /// 还有「保存成功后要补做的事」没做完（比如事件返回剧情后的开场白）。
  bool get _hasPendingAfterSave => _pendingAfterSave != null;

  /// 推进类操作（推进时间 / 发送 / 点事件）前的统一闸门。
  ///
  /// 两个条件都要拦：上次保存失败，**或**还有挂起的保存后动作。
  /// 只检查前者会漏掉这种情况：事件保存失败 → 原提示被顶掉 → 玩家从别的入口
  /// 点了「重试保存」→ 保存成功、失败状态被清掉，但挂起的开场白没人补播。
  /// 重试一律走 [_retryPendingAfterSave]（同一个恢复入口）。
  /// 返回 true = 已拦截，调用方直接 return。
  bool _blockedBySaveFailure() {
    if (!_hasUnsavedFailure && !_hasPendingAfterSave) return false;
    if (!mounted) return true;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          _hasPendingAfterSave
              ? '上一次保存失败，这一步还没做完：$_lastPersistError'
              : '上次保存失败：$_lastPersistError',
        ),
        action: SnackBarAction(
          label: '重试保存',
          onPressed: _retryPendingAfterSave,
        ),
      ),
    );
    return true;
  }

  /// 重试保存是否正在进行（防止连点/多入口并发取同一个挂起动作）。
  bool _retryingPending = false;

  /// 保存失败：挂起 [action] 并给出可重试的提示。
  void _blockAndOfferRetry(Future<void> Function() action) {
    _pendingAfterSave = action;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // 顶掉上一条通用「保存失败」提示：否则两条重试排队，玩家点到的可能是不补播的那条。
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('保存失败：$_lastPersistError（这一步还没执行）'),
        action: SnackBarAction(label: '重试', onPressed: _retryPendingAfterSave),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  /// 重试：先补一次保存，成功才执行挂起的动作；再失败就继续挂着。
  /// 挂起的动作只会被执行一次（[_retryingPending] 闸 + 取出后立刻清空）。
  Future<void> _retryPendingAfterSave() async {
    if (_retryingPending) return;
    _retryingPending = true;
    try {
      final action = _pendingAfterSave;
      await _persist(clearPending: true);
      if (_hasUnsavedFailure) {
        if (action != null) _blockAndOfferRetry(action);
        return;
      }
      _pendingAfterSave = null;
      if (action == null) return;
      appLog.i('chat', '保存重试成功，补执行挂起的动作');
      await action();
    } finally {
      _retryingPending = false;
    }
  }

  Future<void> _persist({bool clearPending = false}) {
    final gen = ++_persistGen;
    // 一次失败不能把队列毒死：否则之后每一次保存都会被静默跳过。
    // 用代次区分：只有「最新一次保存」的成功/失败才更新 _lastPersistError。
    _persistQueue = _persistQueue
        .then((_) => _persistNow(clearPending: clearPending))
        .then((_) {
          // 只有最新代次成功才清错误；旧代次成功不能掩盖新代次的失败。
          if (gen >= _persistGen) {
            _lastPersistError = null;
          }
          _lastPersistedGen = gen;
        })
        .catchError((Object e) {
          // 只有最新代次的失败才记录（旧代次失败已被更新的覆盖）。
          if (gen >= _persistGen) {
            _lastPersistError = '$e';
            debugPrint('[persist] 保存失败：$e');
            // 也给运行日志一份：存档失败是用户反馈里最需要现场证据的一类。
            appLog.e('save', '存档保存失败（gen=$gen，clearPending=$clearPending）', e);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('保存失败，进度可能丢失：$e'),
                  action: SnackBarAction(
                    label: '重试',
                    // 统一走这一个重试入口：有挂起的入场动作时，它会「存成功再补播」，
                    // 而不是只重存一遍、把该做的事漏掉。
                    onPressed: _retryPendingAfterSave,
                  ),
                  duration: const Duration(seconds: 6),
                ),
              );
            }
          }
        });
    return _persistQueue;
  }

  Future<void> _persistNow({bool clearPending = false}) async {
    final services = widget.services;
    if (services == null) return;
    // 不可进入的存档：**一个字节都不许写**（否则会把不支持的档覆盖成当前 schema）。
    if (_saveLocked) return;
    final ref = _ref ?? services.defaultPackageRef();
    if (ref == null) return;
    // 保存前把「当前这张脸」写进世界外观。
    //
    // 模型逐段换表情只改内存里的 _currentExpression / _portraitRequest，
    // world.presentation 一直停在**上一次换幕时**的值。不补这一步，存档里
    // 永远是那会儿的表情 —— 退出游戏再进来就回到旧表情（用户报的「没记住」）。
    final world = _withCurrentLook(_world);
    _world = world;
    if (_saveId == null) {
      final slot = await services.saves.create(
        label: widget.initialSaveLabel?.isNotEmpty == true
            ? widget.initialSaveLabel!
            : '存档 ${DateTime.now().toString().substring(5, 16)}',
        packageRef: ref,
        storyId: '${world.story['storyId'] ?? 'main'}',
        world: world,
        sessionId: _sessionId,
        messages: _messages,
        memory: _memories.toJson(),
      );
      _saveId = slot.saveId;
    }
    // 新建之后立刻再走一次完整 update：让第一份存档就带上世界/记忆/游标/
    // 已结算 id/事件台账，而不是只有骨架。
    final loaded = services.saves.load(_saveId!);
    final slot = loaded.slot;
    if (slot == null) throw StateError('存档无法读取，未保存进度');
    await services.saves.update(
      slot,
      world: world,
      messages: _messages,
      revision: _revision,
      runtimeCursor: _cursor,
      committedTransitions: _committedTransitions,
      appliedSettlementIds: _appliedSettlementIds,
      memoryCheckpoint: _memories.toJson(),
      pendingGalleryUnlocks: _unlockedEventIds.toList(),
      clearPending: clearPending,
    );
  }

  /// 把当前表情/立绘写进世界外观（读档时 `appearance.expressionId` 从这里回来）。
  WorldSnapshot _withCurrentLook(WorldSnapshot world) {
    final look = _currentExpression.trim().isNotEmpty
        ? _currentExpression.trim()
        : _portraitRequest.trim();
    if (look.isEmpty) return world;
    final appearance = world.presentation['appearance'];
    if (appearance is Map && '${appearance['expressionId'] ?? ''}' == look) {
      return world;
    }
    return world.copyWith(
      presentation: {
        ...world.presentation,
        'appearance': {'expressionId': look},
      },
    );
  }

  Future<void> _refreshQuickReplies(
    AIResponse? ai, {
    List<String> suggested = const [],
  }) async {
    if (!mounted) return;
    // 需求 §32：每轮固定两次请求（聊天 + 立绘 agent），快捷回复由 agent 顺带生成。
    // agent / 聊天都没给时**不再**发第三次请求 —— 直接用本地默认值。
    final list = suggested.isNotEmpty
        ? suggested
        : (ai?.suggestedReplies ?? const <String>[]);
    if (list.isNotEmpty) {
      setState(() {
        _qr1 = list[0];
        _qr2 = list.length > 1 ? list[1] : '(安静地陪着她)';
        _qrLoading = false;
      });
      return;
    }
    setState(() {
      _qr1 = '(轻轻点头)';
      _qr2 = '别怕，我在';
      _qrLoading = false;
    });
  }

  /// 正文开始展示；发送仍由回合完成标记保护，不等待后台 agent。
  void _onReplyTextVisible() {
    if (!mounted || _replyUnlocked) return;
    _replyUnlocked = true;
    setState(() {
      _busy = false;
      _qrLoading = true;
    });
  }

  bool get _sendLocked => _busy || _replyInFlight;

  Future<void> _send(String text) async {
    if (text.trim().isEmpty || _sendLocked) return;
    if (_blockedBySaveFailure()) return;
    await _runReplyTask(() => _sendNow(text));
  }

  Future<void> _runReplyTask(Future<void> Function() action) async {
    _replyInFlight = true;
    try {
      await action();
    } finally {
      _replyInFlight = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendNow(String text) async {
    // 上一次保存失败 / 还有挂起的动作：先阻止继续推进，避免内存状态越走越远。
    if (_blockedBySaveFailure()) return;
    _replyEpoch++;
    _lookCancel?.cancel();
    _lookCancel = null;
    _replyUnlocked = false;
    // 校验已过、这一句确实发了出去：收起键盘把画面让给正文。
    // 输入框保持可编辑（生成中仍能写下一句），再点一下即可重新唤起。
    _inputFocus.unfocus();
    setState(() {
      _busy = true;
      _qrLoading = true;
      _items.add(_ChatItem.user(text, animateIn: true));
      _followBottom = true;
    });
    _input.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    final assembled = _buildChatMessages(text);
    final useStream = _streamOutput;
    // 这次提交所属的回合代次：新一轮一发出，这一轮迟到的流式增量就作废。
    final replyEpochAtSubmit = _replyEpoch;
    var liveIdx = -1;
    if (useStream) {
      _liveDelta.clear();
      _streamText = '';
      setState(() {
        _streaming = true;
        liveIdx = _items.length;
        _items.add(_ChatItem.jj('', animateIn: true));
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }

    final outcome = await _coord.submit(
      sessionId: _sessionId,
      world: _world,
      messages: _messages,
      userText: text,
      // 用组装好的上下文（system 块 + L1 活跃窗口 + 立绘表），
      // 而不是让协调器从 _messages 全量重建。
      assembledMessages: assembled,
      audience: _sceneAudience,
      ranges: _variableRanges,
      stream: useStream,
      onDelta: useStream
          ? (d) => _onStreamDelta(d, liveIdx, replyEpochAtSubmit)
          : null,
    );

    if (useStream && mounted) {
      setState(() => _streaming = false);
    }
    if (!mounted) return;

    if (!outcome.accepted) {
      appLog.w('chat', '本轮请求未被接受：${outcome.error ?? '中断'}');
      // 玩家可能已经在等回复时写好了下一句，不覆盖这份草稿。
      if (_input.text.isEmpty) _input.text = text;
      setState(() {
        if (liveIdx >= 0 && liveIdx < _items.length) {
          _items[liveIdx] = _ChatItem.system(
            '（${outcome.error ?? '中断'}，输入已保留）',
          );
        } else {
          _items.add(_ChatItem.system('（${outcome.error ?? '中断'}，输入已保留）'));
        }
        _busy = false;
        _qrLoading = false;
        _replyUnlocked = false;
      });
      _scrollToBottom();
      return;
    }

    _world = outcome.world;
    _messages
      ..clear()
      ..addAll(outcome.messages);

    // 非流式：全文已在手，开始展示；回合闸仍等展示与记录完成。
    if (!useStream) {
      _onReplyTextVisible();
    }

    final ai = outcome.aiResponse;
    await _playReply(
      ai,
      userTextForMemory: text,
      rawText: outcome.rawText,
      streamItemIndex: useStream && liveIdx >= 0 ? liveIdx : null,
      // 玩家自己发起的这一轮：问答两条都播入场动画。
      animateIn: true,
    );
  }

  /// 流式增量：边收边把正文推进打字机气泡（真实网络流，不是本地假打字）。
  /// [epoch] 是发起这次请求时的回合代次：新一轮发出后，旧流迟到的增量必须丢掉，
  /// 否则会写进已经被重建过的消息列表里某个下标。
  void _onStreamDelta(String delta, int idx, int epoch) {
    if (!mounted || idx < 0 || epoch != _replyEpoch) return;
    _liveDelta.write(delta);
    _streamText = _liveDelta.toString();
    setState(() {
      if (idx < _items.length) {
        // 就地改文本：id 与原入场状态跟着原气泡走，逐个增量不会重放入场动画。
        _items[idx] = _items[idx].withText(_streamText);
      }
    });
    // 展示增量不代表回合已结束，发送仍由 _replyInFlight 锁住。
    _onReplyTextVisible();
    if (_followBottom) _scrollToBottom();
  }

  /// 播放一条回复：正文先落地；立绘 agent 与快捷回复并行跟进。
  ///
  /// 立绘走**常驻 agent**（用户第四轮裁定）：
  /// * 聊天请求只负责写台词；
  /// * 每次回复都发一个专用请求：切情绪节拍 + 选立绘 + 顺带快捷回复。
  ///
  /// 完整正文展示并记录后启用发送，不等待 agent；快捷回复在 agent 完成前保持灰色。
  Future<void> _playReply(
    AIResponse? ai, {
    required String userTextForMemory,
    String? rawText,
    int? streamItemIndex,
    bool animateIn = false,
  }) async {
    final epoch = ++_replyEpoch;
    final segs = ai?.segments ?? const <DialogueSegment>[];
    var parts = [for (final s in segs) cleanChatText(s.text)];
    // 占位判据要落在**清洗后**的正文上：分段都在但清洗完没字（例如整段只有格式标记）时，
    // 空串会渲染成一只看不见的气泡，还会在重建消息流时被当空回复整条丢掉。
    final joined = parts.join();
    var full = joined.trim().isEmpty ? '……' : joined;

    final idx = streamItemIndex ?? _items.length;
    final alreadyStreamed = streamItemIndex != null && _streamText.isNotEmpty;
    if (streamItemIndex == null) {
      setState(() {
        // 非流式：先空泡再打字；避免「先全文再打字」的闪烁
        _items.add(_ChatItem.jj('', animateIn: animateIn));
      });
    } else if (alreadyStreamed) {
      // 流式气泡已有正文，这里只保证显示为最终全文（清理增量尾巴）
      setState(() {
        if (idx < _items.length) {
          _items[idx] = _items[idx].withText(full);
        }
      });
    }
    _onReplyTextVisible();

    // 打字机/流式结束后落定文本 + 朗读 + 记忆；不再等立绘 agent。
    Future<void> commitText() async {
      if (!mounted || epoch != _replyEpoch) return;
      setState(() {
        if (idx < _items.length) {
          _items[idx] = _items[idx].withText(full);
        }
      });
      unawaited(
        _maybeAutoRead(parts, idx < _items.length ? _items[idx] : null),
      );
      try {
        await _recordTurn(userTextForMemory, full);
      } catch (_) {
        // 保存失败另有通道提示，后续发送仍由保存失败保护拦截。
      }
    }

    // 立绘 agent：与文字展示并行；完成后再切表情/填快捷回复。
    Future<void> runLookAgent() async {
      final options =
          _session?.availablePortraits(
            state: _effectiveClothing,
            charId: _owner,
          ) ??
          const <String>[];
      final emotions = _session?.primaryEmotions(_owner) ?? const <String>[];
      final plan = await _runLookAgent(
        replyText: full,
        portraitOptions: options,
        emotions: emotions,
        rawText: rawText,
        ai: ai,
      );
      if (!mounted || epoch != _replyEpoch) {
        appLog.d(
          'chat',
          '立绘 agent 迟到结果作废（mounted=$mounted epoch=$epoch/$_replyEpoch）',
        );
        return;
      }
      var parts2 = parts;
      var full2 = full;
      final beats = plan?.usableBeats ?? const [];
      if (beats.isNotEmpty) {
        parts2 = [for (final b in beats) cleanChatText(b.text)];
        full2 = parts2.join();
      }
      final lookSegs = beats.isNotEmpty
          ? [
              for (final b in beats)
                (expression: b.expression, portrait: b.portrait),
            ]
          : [
              for (var i = 0; i < (parts2.isEmpty ? 1 : parts2.length); i++)
                (
                  expression: plan?.replyLook.expression ?? '',
                  portrait: plan?.replyLook.portrait ?? '',
                ),
            ];
      final looks = resolveSegmentLooks(
        segments: lookSegs,
        portraitOptions: options,
        emotions: emotions,
        defaultEmotion: _defaultEmotion,
        current: _currentExpression,
      );
      _logLookQuality(plan, looks);
      if (!mounted || epoch != _replyEpoch) return;
      if (looks.isNotEmpty) {
        _applyLook(looks.last.expression, looks.last.portrait);
      }
      // agent 切出的正文与聊天段可能只差空白：以 agent 结果为准时同步气泡
      if (beats.isNotEmpty && full2 != full) {
        full = full2;
        parts = parts2;
        if (idx < _items.length && !_streaming) {
          setState(() {
            _items[idx] = _items[idx].withText(full);
          });
        }
      }
      unawaited(
        _refreshQuickReplies(ai, suggested: plan?.suggestedReplies ?? const []),
      );
    }

    unawaited(runLookAgent());

    if (alreadyStreamed) {
      _streamText = '';
      _liveDelta.clear();
      // 正文已显示；记忆在 agent 前也可先记（用聊天原文）
      await commitText();
      return;
    }

    // 非流式：展示完成后只提交一次。
    // 调用方等待本轮写入内存上下文，下一轮不能取消这一轮的提交。
    final playback = Completer<void>();
    _textPlaybackDone = playback;
    void finishPlayback() {
      if (playback.isCompleted) return;
      _streamTimer?.cancel();
      _streaming = false;
      playback.complete();
    }

    _runTypewriter(full, (partial) {
      if (!mounted || epoch != _replyEpoch) return;
      setState(() {
        if (idx < _items.length) {
          _items[idx] = _items[idx].withText(partial);
        }
      });
    }, finishPlayback);
    await playback.future;
    if (identical(_textPlaybackDone, playback)) {
      _textPlaybackDone = null;
    }
    await commitText();
  }

  /// 常驻**立绘 agent**：把这条台词切成情绪节拍 + 给每节拍挑合法立绘 + 顺带给
  /// 快捷回复。
  ///
  /// 刻意不走 `_coord.submit`：那样会被当成一轮对话写进消息、算进数值、记进记忆。
  /// 这里只产出「表情与立绘的排布」，对白、数值、记忆一个都不动。
  /// 失败（网络/解析/词表为空）返回 null —— 调用方走稳定兜底（场景默认表情）。
  Future<LookPlan?> _runLookAgent({
    required String replyText,
    required List<String> portraitOptions,
    required List<String> emotions,
    String? rawText,
    AIResponse? ai,
  }) async {
    if (portraitOptions.isEmpty ||
        emotions.isEmpty ||
        replyText.trim().isEmpty) {
      return null;
    }
    final provider = widget.services?.api.createProvider();
    if (provider == null) return null;
    // 诊断：先把「聊天模型到底回了什么」记下来（真机排查的第一手证据）。
    appLog.d(
      'chat',
      '立绘 agent 输入：形态=${(rawText ?? '').trimLeft().startsWith('{') ? 'JSON' : '非 JSON'} '
          '候选立绘(${portraitOptions.length})=${portraitOptions.take(4).join('、')} '
          '情绪表(${emotions.length})=${emotions.take(6).join('、')} '
          '当前形态=「$_effectiveClothing」当前表情=「$_currentExpression」 '
          '原文=${_snippet(replyText)}',
    );
    final token = CancelToken();
    _lookCancel = token;
    // 这一批结果属于哪个回合：玩家抢先发了下一句就作废（与收流后的迟到判定一致）。
    final epoch = _replyEpoch;
    final stream = LookPlanStream();
    // 耗时量化：这个 agent 是**独立一次请求**，只能在台词完整后才发出，
    // 所以「对话秒回、立绘慢」时要能分清是「等首字段」还是「等整段输出」。
    final sw = Stopwatch()..start();
    int? firstLookMs;
    int? firstReplyMs;
    final prompt = buildLookPlanPrompt(
      portraitOptions: portraitOptions,
      emotionOptions: emotions,
      replyText: replyText,
    );
    try {
      final res = await provider.generate(
        GenerateRequest(
          messages: [
            {'role': 'system', 'content': prompt},
          ],
          // agent 也走流式：字段一闭合就先用起来。表情与立绘是 JSON 的头两个字段，
          // 所以它们不再等最后那段（逐拍标注）写完；快捷回复紧跟在后面，也不用等节拍。
          stream: true,
        ),
        cancel: token,
        onDelta: (delta) {
          final arrived = stream.feed(delta);
          if (arrived.isEmpty) return;
          firstLookMs ??= sw.elapsedMilliseconds;
          if (arrived.replies != null) firstReplyMs ??= sw.elapsedMilliseconds;
          if (token.isCancelled || !mounted || epoch != _replyEpoch) return;
          final look = arrived.look;
          if (look != null &&
              (look.expression.isNotEmpty || look.portrait.isNotEmpty)) {
            final resolved = resolveSegmentLooks(
              segments: [
                (expression: look.expression, portrait: look.portrait),
              ],
              portraitOptions: portraitOptions,
              emotions: emotions,
              defaultEmotion: _defaultEmotion,
              current: _currentExpression,
            );
            if (resolved.isNotEmpty) {
              // _applyLook 只改字段，刷新得靠 setState 带出来。
              setState(
                () => _applyLook(
                  resolved.last.expression,
                  resolved.last.portrait,
                ),
              );
              appLog.d(
                'chat',
                '立绘 agent（流式）：表情/立绘先到位 '
                    '「${resolved.last.expression} / ${resolved.last.portrait}」',
              );
            }
          }
          final replies = arrived.replies;
          if (replies != null && replies.isNotEmpty) {
            unawaited(_refreshQuickReplies(ai, suggested: replies));
            appLog.d('chat', '立绘 agent（流式）：快捷回复先到位 ${replies.length} 条');
          }
        },
      );
      sw.stop();
      // 一条汇总：把「感觉慢」变成数字。首字段=表情/立绘可用时刻，首条快捷回复=推荐词
      // 可用时刻，完成=整段回包收完；回包字数明显大于 prompt 篇幅就说明模型没照锚点做
      // （还在把整段台词抄回来），那才是它慢的根因。
      appLog.i(
        'chat',
        '立绘 agent 耗时：首字段=${firstLookMs == null ? '未出现（供应商未流式，或字段顺序不符）' : '${firstLookMs}ms'} '
            '首条快捷回复=${firstReplyMs == null ? '未出现' : '${firstReplyMs}ms'} '
            '完成=${sw.elapsedMilliseconds}ms（prompt ${prompt.length} 字 / 回包 ${(res.rawText ?? '').length} 字）',
      );
      if (token.isCancelled) {
        appLog.d('chat', '立绘 agent 已取消，丢弃结果');
        return null;
      }
      // 传输失败（网络/超时/取消）：没有可解析的正文。
      // 聊天解析器失败（formatError）时 rawText 仍是正文 —— 交给 agent 自己的解析器。
      if (res.rawText == null || res.rawText!.trim().isEmpty) {
        appLog.w('chat', '立绘 agent 请求未成功（${res.status}）：${res.error}');
        return null;
      }
      if (!res.ok && res.status != ProviderStatus.formatError) {
        appLog.w('chat', '立绘 agent 请求未成功（${res.status}）：${res.error}');
        return null;
      }
      if (!res.ok) {
        appLog.d('chat', '立绘 agent：聊天解析未过（${res.error}），改用立绘解析器');
      }
      final parsed = parseLookPlan(res.rawText!, original: replyText);
      if (!parsed.ok) {
        appLog.w(
          'chat',
          '立绘 agent 回包无法解析（${parsed.error}）：${_snippet(parsed.raw)}',
        );
        return null;
      }
      final plan = parsed.plan!;
      appLog.i(
        'chat',
        '立绘 agent：节拍=${plan.beats.length} 重建${plan.reconstructLabel} '
            '总立绘=「${plan.replyLook.portrait}」 快捷回复=${plan.suggestedReplies.length}',
      );
      return plan;
    } catch (e) {
      appLog.w('chat', '立绘 agent 请求失败：$e');
      return null;
    } finally {
      if (identical(_lookCancel, token)) _lookCancel = null;
    }
  }

  /// 立绘质量日志：重建成功 ≠ 立绘选对。分别记精确命中 / 情绪映射 / 兜底。
  void _logLookQuality(LookPlan? plan, List<ResolvedLook> looks) {
    if (looks.isEmpty) return;
    var exact = 0;
    var mapped = 0;
    var fallback = 0;
    for (final l in looks) {
      switch (l.quality) {
        case LookQuality.exact:
          exact++;
        case LookQuality.emotionMapped:
          mapped++;
        case LookQuality.sceneDefault:
        case LookQuality.keptCurrent:
          fallback++;
      }
    }
    appLog.i(
      'chat',
      '立绘落盘：精确=$exact 情绪映射=$mapped 兜底=$fallback 共${looks.length}'
          '${plan != null ? '（agent 节拍=${plan.usableBeats.length}/${plan.beats.length} 重建${plan.reconstructLabel}）' : '（无 agent 计划）'}',
    );
  }

  static String _snippet(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 120 ? '${one.substring(0, 120)}…' : one;
  }

  /// 进入一幕（含第一天）先由对方开口：不带玩家输入请求一条开场白。
  Future<void> _generateOpening() async {
    if (_busy || _streaming || _replyInFlight) return;
    if (_session == null) return;
    await _runReplyTask(_generateOpeningNow);
  }

  Future<void> _generateOpeningNow() async {
    // 用 setState 占住输入框：不然玩家能在开场白还没生成时打字并点发送，
    // 而 _send 会因为 _busy 直接静默丢弃 —— 看起来像「按了没反应」。
    _replyUnlocked = false;
    setState(() {
      _busy = true;
      _qrLoading = true;
    });
    final assembled = _buildChatMessages('');
    final useStream = _streamOutput;
    final replyEpochAtSubmit = _replyEpoch;
    var liveIdx = -1;
    if (useStream) {
      _liveDelta.clear();
      _streamText = '';
      setState(() {
        _streaming = true;
        liveIdx = _items.length;
        _items.add(_ChatItem.jj(''));
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
    final outcome = await _coord.submit(
      sessionId: _sessionId,
      world: _world,
      messages: _messages,
      userText: '',
      assembledMessages: assembled,
      audience: _sceneAudience,
      opening: true,
      ranges: _variableRanges,
      stream: useStream,
      onDelta: useStream
          ? (d) => _onStreamDelta(d, liveIdx, replyEpochAtSubmit)
          : null,
    );
    if (useStream && mounted) {
      setState(() => _streaming = false);
    }
    if (!mounted) {
      _busy = false;
      return;
    }
    if (!outcome.accepted) {
      setState(() {
        if (liveIdx >= 0 && liveIdx < _items.length) {
          _items.removeAt(liveIdx);
        }
        _busy = false;
        _qrLoading = false;
        _replyUnlocked = false;
      });
      debugPrint('[opening] 开场白未生成：${outcome.error ?? '未知'}');
      appLog.w('chat', '开场白未生成：${outcome.error ?? '未知'}');
      return;
    }
    _world = outcome.world;
    _messages
      ..clear()
      ..addAll(outcome.messages);

    if (!useStream) _onReplyTextVisible();

    await _playReply(
      outcome.aiResponse,
      userTextForMemory: '',
      rawText: outcome.rawText,
      streamItemIndex: useStream && liveIdx >= 0 ? liveIdx : null,
    );
  }

  Future<void> _openConsole() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MemoryPage(
          theme: widget.theme,
          l1Count: _memories.windowOf(_owner).length,
          // 只读展示：阈值本身在游戏外设置里调，这里只显示进度与回廊。
          l1Capacity: _memoryThresholds.l1CollapseAt,
          l1KeepRounds: _memoryThresholds.l1KeepRounds,
          cascadeState: _cascadeState,
          // 世界控制台：数值 = 包内注册变量 + 当前值；事件收集 = 触发过的事件
          registry:
              _session?.content.variableRegistry ?? VariableRegistry.empty,
          worldValues: _world.variables,
          events: _session?.eventDefs.values.toList() ?? const <EventDef>[],
          triggeredEventIds: _triggeredEventIds(),
          characters: _session?.content.characters ?? const <CharacterDef>[],
          onOpenMemoryTree: (charId) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MemoryTreePage(
                  theme: widget.theme,
                  bank: _memories,
                  owner: charId,
                  ownerName: charId,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 本幕生效的形态：场景没声明 state 时退回包内默认形态 ——
  /// 否则立绘表是空的，模型没得选，表情就永远不动。
  String get _effectiveClothing =>
      _session?.effectiveState(_clothing, _owner) ?? _clothing;

  Widget _portrait() {
    final t = widget.theme;
    final requested = _portraitRequest.isEmpty
        ? _currentExpression
        : _portraitRequest;
    final path = _session?.portraitPath(
      state: _effectiveClothing,
      requested: requested,
      charId: _owner,
    );
    // key 跟着解析出的文件走：换图时上层的 AnimatedSwitcher 才会交叉淡入。
    final key = ValueKey('portrait:${path ?? 'none'}');
    if (path == null) {
      return KeyedSubtree(key: key, child: _portraitFallback(t));
    }
    if (!_autoRemoveBg) {
      return Image.file(
        File(path),
        key: key,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => KeyedSubtree(
          key: ValueKey('portrait-fallback:$path'),
          child: _portraitFallback(t),
        ),
      );
    }
    // 自动抠图：异步处理纯色背景 → 透明；未完成或失败时先显示原图。
    return FutureBuilder<ui.Image?>(
      key: key,
      future: portraitBgRemover.process(path),
      builder: (context, snap) {
        final img = snap.data;
        if (img == null) {
          // 还在处理 / 失败：显示原图占位，避免闪一下空白。
          return Image.file(
            File(path),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _portraitFallback(t),
          );
        }
        return RawImage(image: img, fit: BoxFit.contain);
      },
    );
  }

  Widget? _backgroundImage() {
    if (!_showBg || _session == null) return null;
    final scene = '${_world.presentation['scene'] ?? ''}';
    if (scene.isEmpty) return null;
    // v2 的 scene 就是 stories/ 下的文件名（如 xx_q.png）。找不到就留空
    // （露出主题色），**不要**回退到某个默认背景 —— 那会显示一张与当前场景
    // 无关的图（以前裸文件名解析失败会掉到 ji_q.png）。
    final path = _session!.sceneBackgroundPath(scene);
    if (path == null) return null;
    return Image.file(
      File(path),
      key: ValueKey('bg:$path'),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }

  Widget _portraitFallback(ChatGalTheme t) {
    return Container(
      width: 200,
      height: 260,
      decoration: BoxDecoration(
        color: t.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Icon(
        Icons.face,
        size: 72,
        color: t.accent.withValues(alpha: 0.35),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    // 不可进入的存档：明确的「不可玩」页，不铺场景、不给输入框。
    if (_saveLocked) return _lockedSaveView(t);
    final memRatio = (_l1RoundCount / _memoryThresholds.l1CollapseAt).clamp(
      0.0,
      1.0,
    );
    // 底部整块的高度只有渲染完才知道（输入栏含快捷回复与安全区），
    // 每帧排一次测量，尺寸稳定后不会再 setState。
    _scheduleBottomMeasure();

    return PopScope(
      canPop: _allowSystemPop,
      onPopInvokedWithResult: (didPop, _) {
        _allowSystemPop = false;
        if (didPop) return;
        _confirmBack();
      },
      child: Theme(
        data: t.toThemeData(),
        child: Scaffold(
          backgroundColor: t.bg,
          resizeToAvoidBottomInset: true,
          body: Stack(
            children: [
              Positioned.fill(
                // 换背景时做交叉淡入（原来是硬切，换幕瞬间很生硬）。
                // 注意布局：AnimatedSwitcher 的默认 layoutBuilder 是
                // `Stack(alignment: center)` —— 非定位子节点只拿到**松约束**，
                // 图片会按自身尺寸居中，于是「背景铺不满」。这里换成
                // StackFit.expand，让每张图都撑满整屏。
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 720),
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [...previous, if (current != null) current],
                  ),
                  child:
                      _backgroundImage() ??
                      SizedBox.expand(
                        key: const ValueKey('bg-empty'),
                        child: ColoredBox(color: t.bg),
                      ),
                ),
              ),
              // Full-bleed list: bubbles can scroll under status bar / top bar.
              Positioned.fill(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.depth != 0) return false;
                    // Any user drag during stream (or anytime) releases follow.
                    if (n is ScrollStartNotification && n.dragDetails != null) {
                      _followBottom = false;
                      return false;
                    }
                    if (n is ScrollUpdateNotification &&
                        n.dragDetails != null) {
                      _followBottom = false;
                      return false;
                    }
                    if (_scroll.hasClients) {
                      final atBottom = _scroll.offset.abs() < 48;
                      if (atBottom) {
                        _followBottom = true;
                      }
                    }
                    return false;
                  },
                  child: ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    // 列表是倒序铺的（下标 0 = 最新），新消息插到末尾会让所有
                    // 下标后移。带上 key + 这个回调，元素才会跟着消息本身走；
                    // 否则正在播的入场动画会被挪到别的气泡身上、或直接被打断。
                    findChildIndexCallback: (key) {
                      if (key is! ValueKey<int>) return null;
                      final at = _items.indexWhere((it) => it.id == key.value);
                      return at < 0 ? null : _items.length - 1 - at;
                    },
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    padding: EdgeInsets.only(
                      left: Spacing.md,
                      right: Spacing.md,
                      // Clear status bar + top pills when scrolled to oldest.
                      top: MediaQuery.paddingOf(context).top + 76,
                      // 底部整块（立绘 + 输入栏）+ 留白调整。实测值拿到前
                      // 退回立绘高度，与设置页预览的公式完全一致。
                      bottom: ChatLayout.messageBottomInset(
                        portraitHeight: _portraitHeight,
                        chatBottomPad: _chatBottomPad,
                        bottomBlockHeight: _bottomBlockHeight,
                      ),
                    ),
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final item = _items[_items.length - 1 - i];
                      return _BubbleEntrance(
                        key: ValueKey<int>(item.id),
                        // 只给本轮新产生的气泡，且一条只播一次。
                        animate:
                            item.animateIn &&
                            !_bubbleEntered.contains(item.id) &&
                            !MediaQuery.disableAnimationsOf(context),
                        onAnimateStart: () => _bubbleEntered.add(item.id),
                        child: _buildBubble(item, t),
                      );
                    },
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Container(
                    height: MediaQuery.paddingOf(context).top + 120,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          t.card.withValues(alpha: 0.88),
                          t.card.withValues(alpha: 0.55),
                          t.card.withValues(alpha: 0.22),
                          t.card.withValues(alpha: 0.0),
                        ],
                        stops: const [0.0, 0.22, 0.55, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: MediaQuery.paddingOf(context).top + 8,
                left: 12,
                child: Row(
                  children: [
                    _circleBtn(
                      t,
                      onTap: _confirmBack,
                      child: Icon(Icons.arrow_back, size: 18, color: t.ink),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 132,
                      height: _topBarHeight,
                      child: Material(
                        color: t.card,
                        borderRadius: BorderRadius.circular(20),
                        elevation: 2,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: _AutoMarqueeText(
                                text: _topTitle,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.1,
                                  fontWeight: FontWeight.w700,
                                  color: t.ink,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _circleBtn(
                      t,
                      onTap: _busy || _streaming || _replyInFlight
                          ? null
                          : _advanceTime,
                      child: Icon(
                        Icons.play_arrow_rounded,
                        size: 18,
                        color: t.accent,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: MediaQuery.paddingOf(context).top + 8,
                right: 12,
                child: SizedBox(
                  height: _topBarHeight,
                  child: _pill(
                    t,
                    onTap: _openConsole,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            value: memRatio,
                            strokeWidth: 2.5,
                            backgroundColor: t.sub.withValues(alpha: 0.2),
                            strokeCap: StrokeCap.round,
                            color: memRatio >= 1 ? Colors.redAccent : t.accent,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.menu, size: 16, color: t.ink),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Column(
                  // 量它：立绘 + 输入栏的整体高度就是消息流要避开的量。
                  key: _bottomBlockKey,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      // 立绘容器高度 = 设置里的 portraitHeight（直接控制）。
                      // 图片顶满容器高度、完整显示（contain）。
                      height: _portraitHeight.clamp(140.0, 420.0),
                      width: double.infinity,
                      child: IgnorePointer(
                        child: Center(
                          child: SizedBox(
                            // 高度顶满容器；宽度不限（contain 会按图片比例收窄）。
                            height: _portraitHeight.clamp(140.0, 420.0),
                            // 立绘逐段切换时交叉淡入，表情变化看得更清楚。
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 220),
                              child: _portrait(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Material(
                      color: t.card,
                      elevation: 12,
                      clipBehavior: Clip.antiAlias,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(20),
                        ),
                      ),
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                          child: Row(
                            // 输入框与发送键要对齐**两个推荐词容器的平分线**（= 左侧
                            // 那一列的垂直中心）。用 end 会让它们贴到推荐词下方，
                            // 看起来像没对齐（用户反馈）。
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _qrChip(
                                    t,
                                    _qr1,
                                    enabled: !_sendLocked && !_qrLoading,
                                    loading: _qrLoading,
                                  ),
                                  const SizedBox(height: 6),
                                  _qrChip(
                                    t,
                                    _qr2,
                                    enabled: !_sendLocked && !_qrLoading,
                                    loading: _qrLoading,
                                  ),
                                ],
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _input,
                                  focusNode: _inputFocus,
                                  // 生成中允许编辑下一句，只禁用发送；过场仍锁住输入。
                                  enabled: !_busy || _replyInFlight,
                                  minLines: 1,
                                  maxLines: 4,
                                  textInputAction: TextInputAction.newline,
                                  decoration: InputDecoration(
                                    isDense: true,
                                    hintText: '说什么(做什么)',
                                    hintStyle: TextStyle(color: t.sub),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                  style: TextStyle(color: t.ink, fontSize: 15),
                                ),
                              ),
                              const SizedBox(width: 4),
                              AnimatedScale(
                                // 忙碌时整颗键轻轻一缩，和图标切换连成一次「按下」。
                                scale: _sendLocked ? 0.94 : 1,
                                duration: MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : const Duration(milliseconds: 220),
                                curve: Curves.easeOutCubic,
                                child: IconButton(
                                  key: const ValueKey('chat-send-button'),
                                  tooltip: _sendLocked ? '正在处理' : '发送',
                                  onPressed: _sendLocked
                                      ? null
                                      : () => _send(_input.text),
                                  icon: _SendButtonGlyph(
                                    busy: _sendLocked,
                                    accent: t.accent,
                                  ),
                                  style: IconButton.styleFrom(
                                    backgroundColor: t.accent.withValues(
                                      alpha: _sendLocked ? 0.18 : 0.12,
                                    ),
                                    // 圆形衬底（原来是圆角矩形，和上面的输入框形状不搭）
                                    shape: const CircleBorder(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 换场期间要等「本幕记忆提炼 + 离场结算」两件设计上必须等的事：
              // 这一段以前屏幕上什么都没有，玩家只看到「点了没反应」。
              if (_leaveStatus != null)
                Positioned(
                  top: MediaQuery.paddingOf(context).top + 64,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: LeaveStatusCard(status: _leaveStatus!, theme: t),
                  ),
                ),
              if (_periodAnim != null)
                PeriodTransitionOverlay(
                  key: ValueKey('period_${_periodAnim!.serial}'),
                  theme: t,
                  day: _periodAnim!.day,
                  sceneName: _periodAnim!.sceneName,
                  atmosphere: _periodAnim!.atmosphere,
                  backgroundPath: _periodAnim!.backgroundPath,
                  onFinished: _finishPeriodTransition,
                ),
              if (_eventPlay != null) _buildEventOverlay(t),
            ],
          ),
        ),
      ),
    );
  }

  /// 事件播放层：整屏图（有图时）+ 屏幕下中部的整屏文字 + 「点击下一块」。
  ///
  /// 一块 = 一屏：块里的多句在这里**换行一起显示**，点一下翻下一块
  /// （这是旧项目结局页的形态：全屏插图 + 下半屏文字 + 点击推进）。
  Widget _buildEventOverlay(ChatGalTheme t) {
    final play = _eventPlay!;
    final event = _eventCoord.event(play.eventId);
    final frame = _eventCoord.currentFrame(play);
    final imagePath = frame?.image == null
        ? null
        : _session?.eventAssetPath(play.eventId, frame!.image!);
    final hasImage = imagePath != null;
    final ink = hasImage ? Colors.white : t.ink;
    // 进度点按**块数**算（一块 = 一屏）。
    final totalFrames = event?.frames.length ?? 0;
    // 最后一屏 + 这个事件写的是选择题出口：这一屏不再「点一下结束」，
    // 而是把选项铺出来让玩家点（点哪个就去哪个）。
    final choice = _eventCoord.choiceOf(play);
    final atChoice = choice != null && _eventCoord.canFinish(play);

    return Positioned.fill(
      child: GestureDetector(
        onTap: () => _onEventTap(),
        child: AnimatedSwitcher(
          // 切张时淡入淡出，而不是硬切
          duration: const Duration(milliseconds: 280),
          // 交叉淡入时新旧两层的 alpha 都不足 1，加起来的合成不透明度也到不了 1
          // —— 于是底下的**聊天界面**会从缝里透出来（用户报障）。
          // 在全部层**下面**垫一块不透明的底：过渡期间露出来的是事件层自己的
          // 底色，不再是下面的对话。
          layoutBuilder: (current, previous) => Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: hasImage ? Colors.black : t.bg),
              ...previous,
              ?current,
            ],
          ),
          child: SizedBox.expand(
            key: ValueKey('${play.eventId}#${play.slideIndex}'),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasImage)
                  Image.file(
                    File(imagePath),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => ColoredBox(color: t.bg),
                  ),
                // 遮罩：下半屏压暗，保证文字可读（有图时还要保证画面上部透出来）
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: hasImage
                          ? [
                              Colors.black.withValues(alpha: 0.34),
                              Colors.black.withValues(alpha: 0.16),
                              Colors.black.withValues(alpha: 0.82),
                            ]
                          : [
                              t.bg.withValues(alpha: 0.97),
                              t.bg.withValues(alpha: 0.97),
                            ],
                      stops: hasImage ? const [0.0, 0.45, 1.0] : null,
                    ),
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          event?.id ?? play.eventId,
                          style: TextStyle(
                            color: hasImage
                                ? Colors.white.withValues(alpha: 0.92)
                                : t.ink,
                            fontSize: 16,
                            letterSpacing: 2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        // 整屏文字、选项（最多 5 个）和进度点一起**贴底**显示：
                        // `reverse: true` 让内容不足一屏时贴底（观感与从前一致），
                        // 超过一屏时改为可滚动 —— 而且优先露出底部的**选项按钮**，
                        // 因为选择题的出口就在按钮上（点空白处是不响应的，
                        // 按钮掉到屏幕外会让玩家以为「点了没反应」）。
                        Expanded(
                          child: SingleChildScrollView(
                            reverse: true,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  frame?.text ?? '',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: ink,
                                    fontSize: 19,
                                    height: 1.75,
                                    shadows: hasImage
                                        ? const [
                                            Shadow(
                                              blurRadius: 10,
                                              color: Colors.black87,
                                            ),
                                          ]
                                        : null,
                                  ),
                                ),
                                const SizedBox(height: 22),
                                if (atChoice) ...[
                                  if (choice.title.trim().isNotEmpty) ...[
                                    Text(
                                      choice.title,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: ink,
                                        fontSize: 15,
                                        height: 1.5,
                                        fontWeight: FontWeight.w700,
                                        shadows: hasImage
                                            ? const [
                                                Shadow(
                                                  blurRadius: 10,
                                                  color: Colors.black87,
                                                ),
                                              ]
                                            : null,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                  for (final o in choice.options)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: OutlinedButton(
                                        onPressed: _eventFinishing
                                            ? null
                                            : () => _chooseEventExit(o),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: ink,
                                          backgroundColor: Colors.black
                                              .withValues(alpha: 0.28),
                                          side: BorderSide(
                                            color:
                                                (hasImage
                                                        ? Colors.white
                                                        : t.accent)
                                                    .withValues(alpha: 0.7),
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 13,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                        ),
                                        child: Text(
                                          o.text,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: 14.5,
                                            color: ink,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                  Text(
                                    '选一个继续',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: hasImage
                                          ? Colors.white.withValues(alpha: 0.7)
                                          : t.sub,
                                      fontSize: 12,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                ] else
                                  Text(
                                    _eventCoord.canFinish(play)
                                        ? '点击结束'
                                        : '点击下一块',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: hasImage
                                          ? Colors.white.withValues(alpha: 0.7)
                                          : t.sub,
                                      fontSize: 12,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                if (totalFrames > 1) ...[
                                  const SizedBox(height: 10),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      for (var i = 0; i < totalFrames; i++)
                                        Container(
                                          width: i == play.slideIndex ? 16 : 6,
                                          height: 6,
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color:
                                                (hasImage
                                                        ? Colors.white
                                                        : t.accent)
                                                    .withValues(
                                                      alpha:
                                                          i == play.slideIndex
                                                          ? 0.95
                                                          : 0.35,
                                                    ),
                                            borderRadius: BorderRadius.circular(
                                              3,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onEventTap() async {
    final play = _eventPlay;
    if (play == null) return;
    // 收尾要走一次网络/落盘，期间 _eventPlay 还没清；这时再点一下会走到
    // finish() 第二遍 → 出口判定被跑两次。加个闸。
    if (_eventFinishing) return;
    // 上一次保存失败 / 还有挂起的入场动作：阻止继续翻页/收尾。
    if (_blockedBySaveFailure()) return;
    final next = _eventCoord.advance(play);
    if (next != null) {
      // 同步推进光标（含 slideIndex）并落盘：`_eventPlay` 只是界面状态，
      // 不落盘的话杀掉进程再进来会从事件第一格重播。
      setState(() => _setEventPlay(next));
      unawaited(_persist());
      return;
    }
    // finish
    // 选择题出口：最后一屏交给玩家点选项，点空白处不结束（否则会绕过选择题）。
    if (_eventCoord.choiceOf(play) != null) return;
    final draft = _eventCoord.finish(play);
    // 注意：**不能**用 `_committedTransitions.contains(draft.commitId)` 来挡重入 ——
    // 事件的 eventVisitId 现在是累计递增的，但同一事件的重复收尾仍可能撞 id；
    // 真正挡住「点两下」的是下面的 `_eventFinishing` 闸。
    _eventFinishing = true;
    try {
      await _finishEvent(draft);
    } finally {
      _eventFinishing = false;
    }
  }

  /// 玩家点了选择题里的某个选项：出口就是它写的目的地。
  ///
  /// 与 [TargetRouter] 那条路不同：不判定任何条件、不消耗随机数 ——
  /// 选择题的意义就是「出口由玩家决定」。
  Future<void> _chooseEventExit(EventChoiceOption option) async {
    final play = _eventPlay;
    if (play == null || _eventFinishing) return;
    if (_blockedBySaveFailure()) return;
    if (!_eventCoord.canFinish(play)) return;
    final draft = _eventCoord.finish(play);
    _eventFinishing = true;
    setState(() {});
    try {
      await _finishEvent(draft, chosen: option.target);
    } finally {
      _eventFinishing = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _finishEvent(
    EventFinishDraft draft, {
    ExitTarget? chosen,
  }) async {
    var world = _world;
    final vars = Map<String, Object?>.from(world.variables);
    // 事件收集：这个事件到此为止算触发过（持久化在 pendingGalleryUnlocks）。
    // 世界控制台显示的名字就是**事件所在文件夹名**。
    _unlockedEventIds.add(draft.eventId);
    _committedTransitions.add(draft.commitId);
    final day = (_world.variables['day'] as num?)?.toInt() ?? _day;

    // 播完之后走的是**和情景完全一样**的出口判定：自上而下首个 require 成立的
    // 块被锁定，块内等概率。选择题出口则直接用玩家点的那个选项。
    final ExitTarget? route;
    if (chosen != null) {
      route = chosen;
    } else {
      route = _router.route(draft.target, world, rngState: world.rngState);
      // 消费一次随机：与情景换幕一致，保证同一份存档重放的结果可复现。
      world = world.copyWith(rngState: world.rngState + 1);
    }

    if (route == null) {
      // 事件没有出口（或条件都不成立）：不算错误，提示一句、退回对话层。
      // 光标必须同步切回 storyChat：否则存档里还是 eventPlay，
      // 保存后重进会恢复已经结束的事件。
      _world = world;
      final storyCursor = RuntimeCursor(
        mode: RuntimeCursor.modeStoryChat,
        storyId: '${world.story['storyId'] ?? ''}',
        visitId: _cursor.visitId,
        eventVisitId: _cursor.eventVisitId,
      );
      _setCursor(storyCursor);
      setState(() {
        _eventPlay = null;
        _items.add(_ChatItem.system('事件结束：${draft.eventId}'));
      });
      await _persist(clearPending: true);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('暂时不能进入下一阶段噢')));
      }
      return;
    }

    switch (route.kind) {
      case 'story':
        final to = route.to;
        final nextScene = _session?.content.scenes[to];
        if (nextScene == null) {
          _world = world;
          _setCursor(
            RuntimeCursor(
              mode: RuntimeCursor.modeStoryChat,
              storyId: '${world.story['storyId'] ?? ''}',
              visitId: _cursor.visitId,
              eventVisitId: _cursor.eventVisitId,
            ),
          );
          setState(() {
            _eventPlay = null;
            _items.add(_ChatItem.system('事件结束：${draft.eventId}'));
          });
          await _persist(clearPending: true);
          return;
        }
        // 目标情景的入场 fixedEffects（正数为加、负数为减）。
        applyVariableChanges(
          vars,
          nextScene.fixedEffects,
          registry:
              _session?.content.variableRegistry ?? VariableRegistry.empty,
        );
        final nextCursor = RuntimeCursor(
          mode: RuntimeCursor.modeStoryChat,
          storyId: to,
          visitId: _cursor.visitId + 1,
          // 事件访问号带着走，否则下一次进事件又从 1 开始数（commitId 撞车）。
          eventVisitId: _cursor.eventVisitId,
        );
        _applyActors(nextScene.characters);
        world = world.copyWith(
          variables: vars,
          story: {
            ...world.story,
            'storyId': to,
            'nodeId': to,
            'day': vars['day'],
          },
          presentation: {
            ...world.presentation,
            'scene': nextScene.background ?? world.presentation['scene'],
            'narration': nextScene.narration,
            'actors': nextScene.characters.map((a) => a.toJson()).toList(),
            'cursor': nextCursor.toJson(),
          },
        );
        _world = world;
        _setCursor(nextCursor);
        // 注意顺序：`..._messages` 必须在 clear 之前取值。写成
        // `_messages..clear()..addAll([..._messages, X])` 会把全量聊天记录
        // 截成只剩一条场景卡，而 _persist 把它当 messageCheckpoint 落盘 ——
        // 「记录仍在存档里」当场就假了。
        final dayAfter = (vars['day'] as num?)?.toInt() ?? day;
        _messages.add({
          'role': 'system',
          'is_system': true,
          'content':
              '第$dayAfter天 · ${nextScene.displayName}\n${nextScene.narration}',
        });
        setState(() {
          _eventPlay = null;
          _items.add(
            _ChatItem.scene(
              '第$dayAfter天 · ${nextScene.displayName}',
              nextScene.narration,
            ),
          );
        });
        _markOpeningPending();
        await _persist(clearPending: true);
        // 保存失败就不播过场、不请求开场白（与普通换幕同一条规则）：
        // 进度没落盘还继续产生对白与记忆，等于制造一段必然丢的内容。
        if (_hasUnsavedFailure) {
          _blockAndOfferRetry(_enterSceneOpening);
          return;
        }
        // 新一幕开始：先换幕过场，再让对方开口
        if (mounted) {
          await _enterSceneOpening();
        }
        return;

      case 'event':
        final to = route.to;
        _world = world;
        setState(() {
          _setEventPlay(
            EventPlayState(
              eventId: to,
              eventVisitId: (_cursor.eventVisitId ?? 0) + 1,
              slideIndex: 0,
              storyVisitId: _cursor.visitId,
            ),
          );
        });
        await _persist(clearPending: true);
        return;

      case 'appShell':
        _world = world;
        // 回主页：运行位清干净，否则重进会恢复在已结束的事件上。
        _setCursor(
          RuntimeCursor(
            mode: RuntimeCursor.modeStoryChat,
            storyId: '${world.story['storyId'] ?? ''}',
            visitId: _cursor.visitId,
            eventVisitId: _cursor.eventVisitId,
          ),
        );
        await _persist(clearPending: true);
        // 与普通换幕的 appShell 出口同一条规则：没落盘就不弹回主页，
        // 否则玩家以为存上了、其实这一场的结果丢了。
        if (_hasUnsavedFailure) {
          _blockAndOfferRetry(() async {
            if (!mounted) return;
            setState(() => _eventPlay = null);
            _popToHome();
          });
          return;
        }
        if (!mounted) return;
        setState(() => _eventPlay = null);
        // 出口就是「回主页」：真的要弹回去，绕过 PopScope 确认。
        _popToHome();
        return;

      default:
        _world = world;
        _setCursor(
          RuntimeCursor(
            mode: RuntimeCursor.modeStoryChat,
            storyId: '${world.story['storyId'] ?? ''}',
            visitId: _cursor.visitId,
            eventVisitId: _cursor.eventVisitId,
          ),
        );
        setState(() {
          _eventPlay = null;
          _items.add(_ChatItem.system('事件结束：${draft.eventId}'));
        });
        await _persist(clearPending: true);
        return;
    }
  }

  /// 存档不可进入时的页面：说明原因 + 一个「返回主页」。
  /// 只有两个出口，且**不做任何写盘** —— 原档要保持一个字节不变。
  Widget _lockedSaveView(ChatGalTheme t) {
    return Theme(
      data: t.toThemeData(),
      child: Scaffold(
        backgroundColor: t.bg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 40, color: t.sub),
                const SizedBox(height: 14),
                Text(
                  '这份存档打不开',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: t.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '原因：$_saveLockedReason\n\n'
                  '为了避免把你的存档写坏，这里不会做任何保存，也不会用新游戏覆盖它。\n'
                  '通常是这个档由更高版本或不同格式写出来的 —— 请用对应版本的客户端打开，'
                  '或者回到主页另开一个新档。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, height: 1.6, color: t.sub),
                ),
                const SizedBox(height: 22),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: t.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 13,
                    ),
                  ),
                  onPressed: () {
                    // 锁档页离开时同样交回 null（见 _confirmBack 的说明）。
                    if (mounted) Navigator.of(context).pop();
                  },
                  child: const Text('返回主页'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pill(ChatGalTheme t, {required Widget child, VoidCallback? onTap}) {
    return Material(
      color: t.card,
      borderRadius: BorderRadius.circular(20),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: SizedBox(
          height: _topBarHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DefaultTextStyle(
              style: TextStyle(fontSize: 13, color: t.ink),
              child: Center(widthFactor: 1, child: child),
            ),
          ),
        ),
      ),
    );
  }

  Widget _circleBtn(
    ChatGalTheme t, {
    required Widget child,
    VoidCallback? onTap,
  }) {
    // onTap == null 就是禁用态：这里压一层透明度，让玩家看得出「现在点不动」，
    // 而不是以为按钮坏了。立绘/快捷回复/发送键都有对应的视觉反馈，这里也补上。
    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: Material(
        color: t.card,
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: _topBarHeight,
            height: _topBarHeight,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }

  Widget _qrChip(
    ChatGalTheme t,
    String text, {
    required bool enabled,
    bool loading = false,
  }) {
    final fg = loading || !enabled ? t.sub.withValues(alpha: 0.55) : t.ink;
    return Opacity(
      opacity: loading ? 0.55 : 1,
      child: Material(
        color: t.bg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled
              ? () {
                  final s = text.trim();
                  if (s.isEmpty) return;
                  _send(s);
                }
              : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              loading ? '…' : text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: fg),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBubble(_ChatItem item, ChatGalTheme t) {
    if (item.kind == _ItemKind.system) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: t.card,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              item.text,
              style: TextStyle(fontSize: 12, color: t.sub),
            ),
          ),
        ),
      );
    }

    if (item.kind == _ItemKind.scene) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 340),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: t.card,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title ?? '场景',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: t.ink,
                  ),
                ),
                if (item.text.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ActionText(
                    item.text,
                    ink: t.ink,
                    actionColor: t.sub,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    final isUser = item.kind == _ItemKind.user;
    // 正在流式落地的那条不朗读（文字还没齐），按钮先不显示。
    final streamingNow =
        _streaming && _items.isNotEmpty && identical(item, _items.last);
    final canSpeak =
        !isUser &&
        _ttsSettings.enabled &&
        item.text.trim().isNotEmpty &&
        !streamingNow;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Container(
            margin: EdgeInsets.only(bottom: canSpeak ? 2 : 10),
            constraints: const BoxConstraints(maxWidth: 280),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isUser ? t.userBubble : t.jjBubble,
              borderRadius: BorderRadius.circular(16),
            ),
            child: ActionText(
              item.text.isEmpty && _streaming && !isUser ? '…' : item.text,
              ink: isUser ? Colors.white : t.ink,
              actionColor: isUser
                  ? Colors.white.withValues(alpha: 0.75)
                  : t.sub,
              style: _chatStyle(isUser ? Colors.white : t.ink),
            ),
          ),
          if (canSpeak) _speakButton(t, item),
        ],
      ),
    );
  }

  /// 气泡下面那行「朗读 / 停止」。
  Widget _speakButton(ChatGalTheme t, _ChatItem item) {
    final speaking = identical(_speakingToken, item);
    final busy =
        speaking &&
        (_tts?.state == TtsState.preparing || _tts?.state == TtsState.playing);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () {
            if (busy) {
              _stopSpeaking();
            } else {
              _speakBubble(item);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (speaking && _tts?.state == TtsState.preparing)
                  SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: t.sub,
                    ),
                  )
                else
                  Icon(
                    busy
                        ? Icons.stop_circle_outlined
                        : Icons.volume_up_outlined,
                    size: 13,
                    color: speaking ? t.accent : t.sub,
                  ),
                const SizedBox(width: 4),
                Text(
                  _tts?.state == TtsState.preparing && speaking
                      ? '合成中'
                      : (busy ? '停止' : '朗读'),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: speaking ? t.accent : t.sub,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _ItemKind { user, jj, system, scene }

/// 换幕过场要显示的内容：第几天、情景名、气氛句、以及要进入那一幕的背景图。
class _PeriodAnim {
  const _PeriodAnim({
    required this.day,
    required this.sceneName,
    required this.atmosphere,
    required this.serial,
    this.backgroundPath,
  });

  final int day;
  final String sceneName;

  /// 包声明的转场气氛；空串则过场只显示天与情景名。
  final String atmosphere;

  /// 要进入那一幕的聊天背景（绝对路径）。null = 那一幕没有背景图，
  /// 或者设置里关掉了「显示场景背景」——过场退回纯色薄纱。
  final String? backgroundPath;

  /// 每次过场都换一个 key，逼 Flutter 重建 overlay 让动画重新跑。
  final int serial;
}

class _ChatItem {
  _ChatItem.user(this.text, {this.animateIn = false})
    : kind = _ItemKind.user,
      title = null,
      id = _nextId++;

  _ChatItem.jj(this.text, {this.animateIn = false})
    : kind = _ItemKind.jj,
      title = null,
      id = _nextId++;

  _ChatItem.system(this.text)
    : kind = _ItemKind.system,
      title = null,
      animateIn = false,
      id = _nextId++;

  _ChatItem.scene(String title, String body)
    : kind = _ItemKind.scene,
      title = title,
      text = body,
      animateIn = false,
      id = _nextId++;

  _ChatItem._({
    required this.id,
    required this.kind,
    required this.text,
    required this.title,
    required this.animateIn,
  });

  /// 同一个气泡换正文（流式增量、打字机逐帧重画）：
  /// id 与入场状态跟着原气泡走，否则每个增量都会重放一次入场动画。
  _ChatItem withText(String text) => _ChatItem._(
    id: id,
    kind: kind,
    text: text,
    title: title,
    animateIn: animateIn,
  );

  static int _nextId = 0;

  /// 列表里认这个 id（也当 widget key 用）：一条消息一个 id，永不重复。
  /// 重建消息流时同级同正文的气泡会**沿用原对象**，所以 id 与对象身份都能跨轮稳定。
  final int id;
  final _ItemKind kind;
  final String text;
  final String? title;

  /// 是否播入场动画。只有玩家发起的这一轮新产生的气泡是 true；
  /// 读档、起始场景铺出来的历史消息一律 false。
  final bool animateIn;
}

/// 气泡入场：从下方 14px 轻轻上移 + 淡入，只在新气泡第一次出现时播一次。
///
/// 要不要播只认**第一次挂载**时的参数，之后父级重建（流式每个增量都会重建）
/// 不会重放，也不会被中途掐断。滚出可视区再滚回来时列表会重建这个元素，
/// 那时 [animate] 已经是 false（调用方用「已播过」集合保证）。
class _BubbleEntrance extends StatefulWidget {
  const _BubbleEntrance({
    super.key,
    required this.animate,
    required this.child,
    this.onAnimateStart,
  });

  final bool animate;
  final Widget child;
  final VoidCallback? onAnimateStart;

  @override
  State<_BubbleEntrance> createState() => _BubbleEntranceState();
}

class _BubbleEntranceState extends State<_BubbleEntrance>
    with SingleTickerProviderStateMixin {
  late final bool _animated = widget.animate;
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  late final Animation<double> _eased = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    // 先在这里碰一下控制器，让 Ticker 当场建好。否则 animate=false 的气泡
    // 只会在 dispose() 里第一次访问它，等于在已经 defunct 的 State 上建 Ticker。
    _ctrl.value = _animated ? 0 : 1;
    if (_animated) {
      widget.onAnimateStart?.call();
      _ctrl.forward();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_animated) return widget.child;
    return AnimatedBuilder(
      animation: _eased,
      child: widget.child,
      builder: (context, child) {
        final t = _eased.value.clamp(0.0, 1.0);
        return Opacity(
          // 认这一层入场用的标记（同一时刻可能好几个气泡在播）。
          key: const ValueKey('chat-bubble-enter'),
          opacity: t,
          // 只做绘制期位移，不参与布局，不会把相邻气泡顶来顶去。
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 14),
            child: child,
          ),
        );
      },
    );
  }
}

/// 发送键的图标：空闲箭头 / 忙碌进度环。
///
/// 箭头出现时会放大淡入弹一下；退场不做动画——忙碌环必须**立刻**离开
/// widget 树，否则按钮解锁后进度环还在树里淡出，等于还在转圈。
class _SendButtonGlyph extends StatefulWidget {
  const _SendButtonGlyph({required this.busy, required this.accent});

  final bool busy;
  final Color accent;

  @override
  State<_SendButtonGlyph> createState() => _SendButtonGlyphState();
}

class _SendButtonGlyphState extends State<_SendButtonGlyph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _eased = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeOutBack,
  );

  @override
  void initState() {
    super.initState();
    // 首帧就摆好箭头，不做「页面刚打开箭头才弹出来」的延迟。
    _ctrl.value = widget.busy ? 0 : 1;
  }

  @override
  void didUpdateWidget(covariant _SendButtonGlyph old) {
    super.didUpdateWidget(old);
    // 忙碌 → 空闲：箭头重新弹回来。
    if (old.busy && !widget.busy) _ctrl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    if (widget.busy) {
      return SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: widget.accent,
          backgroundColor: widget.accent.withValues(alpha: 0.16),
          value: still ? 0.75 : null,
          semanticsLabel: '正在处理',
        ),
      );
    }
    final arrow = Icon(
      Icons.arrow_upward_rounded,
      color: widget.accent,
      size: 26,
    );
    if (still) return arrow;
    return AnimatedBuilder(
      animation: _eased,
      child: arrow,
      builder: (context, child) {
        final t = _eased.value;
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.scale(scale: 0.6 + 0.4 * t, child: child),
        );
      },
    );
  }
}

/// Horizontal marquee: loops when longer than 8 chars or wider than viewport.
/// Edges fade so the hard clip does not look truncated.
class _AutoMarqueeText extends StatefulWidget {
  const _AutoMarqueeText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_AutoMarqueeText> createState() => _AutoMarqueeTextState();
}

class _AutoMarqueeTextState extends State<_AutoMarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  );
  double _overflow = 0;

  bool get _shouldScroll => _overflow > 0;

  @override
  void initState() {
    super.initState();
    _ctrl.addStatusListener((status) {
      if (!mounted || !_shouldScroll) return;
      if (status == AnimationStatus.completed) {
        Future<void>.delayed(const Duration(milliseconds: 500), () {
          if (mounted && _shouldScroll) _ctrl.reverse();
        });
      } else if (status == AnimationStatus.dismissed) {
        Future<void>.delayed(const Duration(milliseconds: 500), () {
          if (mounted && _shouldScroll) _ctrl.forward();
        });
      }
    });
  }

  @override
  void didUpdateWidget(covariant _AutoMarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.style != widget.style) {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double _textWidth() {
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: double.infinity);
    return tp.width;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final tw = _textWidth();
        // Only marquee when text actually exceeds the fixed pill width.
        final need = maxW.isFinite && tw > maxW + 1;
        final overflow = need ? math.max(tw - maxW, 0.0) : 0.0;

        if ((overflow - _overflow).abs() > 0.5) {
          _overflow = overflow;
          if (overflow > 0) {
            _ctrl.duration = Duration(
              milliseconds: (overflow * 60).clamp(2400.0, 12000.0).round(),
            );
            if (!_ctrl.isAnimating) {
              _ctrl.forward(from: 0);
            }
          } else {
            _ctrl.stop();
            _ctrl.value = 0;
          }
        }

        // Full natural width — never let the viewport width clip the Text layout.
        final text = Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: widget.style,
        );

        if (!_shouldScroll) {
          return SizedBox(
            width: maxW.isFinite ? maxW : null,
            height: widget.style.fontSize != null
                ? (widget.style.fontSize! * (widget.style.height ?? 1.2))
                : 16,
            child: Align(alignment: Alignment.centerLeft, child: text),
          );
        }

        return SizedBox(
          width: maxW.isFinite ? maxW : null,
          height: widget.style.fontSize != null
              ? (widget.style.fontSize! * (widget.style.height ?? 1.2))
              : 16,
          child: ClipRect(
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) {
                return LinearGradient(
                  colors: const [
                    Colors.transparent,
                    Colors.black,
                    Colors.black,
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.12, 0.88, 1.0],
                ).createShader(rect);
              },
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: 0,
                maxWidth: double.infinity,
                minHeight: 0,
                maxHeight: double.infinity,
                child: AnimatedBuilder(
                  animation: _ctrl,
                  builder: (context, _) {
                    return Transform.translate(
                      offset: Offset(-_ctrl.value * _overflow, 0),
                      child: text,
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
