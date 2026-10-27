import 'dart:async';

/// 按 key 串行化的写盘队列（同一个 key 排队，不同 key 互不阻塞）。
///
/// 两个用途：
/// * 同一个文件的并发写不能互相覆盖 —— 各自写临时文件再改名时，
///   别人可能把自己**写了一半**的临时文件改成正式文件；
/// * 队列**在任务完成后就移除条目**：早先 StudioStore 只往里塞不删，
///   长时间编辑一个工程会一直攒着「已经完成的 future」，白占内存。
class SerialWrites {
  final Map<String, Future<void>> _tails = {};

  /// 把 [task] 接在 [key] 的队尾；返回**这一次写入本身**的结果
  /// （失败如实抛出，不会被队列吞掉）。
  Future<void> run(String key, Future<void> Function() task) {
    final prev = _tails[key] ?? Future<void>.value();
    final mine = prev.then((_) => task());
    // 队尾只负责「排到哪儿了」：吞掉错误，避免一次失败毒死后续写入。
    final tail = mine.then<void>((_) {}, onError: (Object _) {});
    _tails[key] = tail;
    unawaited(tail.then((_) {
      if (identical(_tails[key], tail)) _tails.remove(key);
    }));
    return mine;
  }

  /// 等**调用这一刻已经入队**的写（快照语义：之后新入队的写不在等待范围内）。
  Future<void> flush([bool Function(String key)? test]) {
    final pending = _tails.entries
        .where((e) => test == null || test(e.key))
        .map((e) => e.value)
        .toList();
    return Future.wait(pending).then((_) {});
  }

  /// 队列里还剩多少条（测试用；正常情况下任务完成即归零）。
  int get pendingCount => _tails.length;
}
