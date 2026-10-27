import 'package:gal_protocol/gal_protocol.dart';
import 'package:gal_storage/gal_storage.dart';

/// 同包升级允许继续，但不能把缺失的运行位置悄悄替换成 start。
String? savePositionError(SaveSlot slot, PackageContent content) {
  final cursor = slot.runtimeCursor;
  if (cursor.visitId < 0 || (cursor.eventVisitId ?? 0) < 0) {
    return '存档访问号无效';
  }
  final characters = content.characters.map((c) => c.id).toSet();
  if (cursor.mode == RuntimeCursor.modeEventPlay) {
    final event = content.eventDefs[cursor.eventId];
    if (event == null) return '当前内容包缺少存档事件：${cursor.eventId}';
    final index = cursor.slideIndex ?? 0;
    if (index < 0 || index >= event.frames.length) return '存档事件页码已超出当前事件';
  } else if (cursor.mode != RuntimeCursor.modeStoryChat) {
    return '不支持的存档运行模式：${cursor.mode}';
  }
  final ids = <String>{
    if (cursor.storyId != null) cursor.storyId!,
    for (final key in ['storyId', 'nodeId'])
      if (slot.world.story[key] is String &&
          '${slot.world.story[key]}'.isNotEmpty)
        '${slot.world.story[key]}',
  };
  if (cursor.mode == RuntimeCursor.modeStoryChat && ids.isEmpty) {
    return '存档缺少剧情位置';
  }
  for (final id in ids) {
    final scene = content.scenes[id];
    if (scene == null) return '当前内容包缺少存档情景：$id';
    if (scene.characters.any((a) => !characters.contains(a.charId))) {
      return '存档情景引用的角色已不存在：$id';
    }
  }
  if (cursor.mode == RuntimeCursor.modeStoryChat && ids.length > 1) {
    return '存档剧情位置不一致，不能自动选择入口覆盖进度';
  }
  return null;
}
