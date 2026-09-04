import 'dart:io';

import 'package:clipshare/app/data/enums/syncing_file_state.dart';
import 'package:clipshare/app/data/models/syncing_file.dart';
import 'package:clipshare/app/modules/sync_file_module/sync_file_controller.dart';
import 'package:clipshare/app/utils/log.dart';
import 'package:get/get.dart';

class SyncingFileProgressService extends GetxService {
  /// 以 [SyncingFile.recordKey] 为键。发送记录使用唯一键，
  /// 因此同一文件发给多个设备、或失败后重发，都不会相互覆盖。
  final _syncingFilesMap = <String, SyncingFile>{}.obs;

  Future<SyncingFileProgressService> init() async {
    // 构建标记：用于从日志确认安装的 APK 是否包含"进度保留+重发"功能。
    // 若日志中看不到本行，说明构建源码未包含修复文件。
    logger.info("BuildMarker", "records-resend-v3 build 2026-09-05");
    return this;
  }

  void updateSyncingFile(SyncingFile syncingFile) {
    _syncingFilesMap[syncingFile.recordKey] = syncingFile;
    _postHandle(syncingFile);
  }

  void removeSyncingFile(String recordKey) {
    if (!_syncingFilesMap.containsKey(recordKey)) return;
    var syncingFile = _syncingFilesMap[recordKey];
    _syncingFilesMap.remove(recordKey);
    _postHandle(syncingFile!);
  }

  /// 重发一条发送记录。找不到记录或该记录不支持重发时返回 false。
  Future<bool> retry(String recordKey) async {
    final syncingFile = _syncingFilesMap[recordKey];
    if (syncingFile == null || !syncingFile.canRetry) return false;
    await syncingFile.retry();
    return true;
  }

  void clearAll() {
    _syncingFilesMap.clear();
  }

  void _postHandle(SyncingFile syncingFile) {
    var isSender = syncingFile.isSender;
    switch (syncingFile.state) {
      case SyncingFileState.error:
        // 仅接收端失败时删除写坏的本地文件；发送端保留记录以便重发。
        if (isSender) break;
        File(syncingFile.filePath).delete();
        break;
      case SyncingFileState.done:
        final controller = Get.find<SyncFileController>();
        controller.refreshHistoryFiles();
        break;
      default:
    }
  }

  List<SyncingFile> get syncingFiles {
    final list = _syncingFilesMap.values.toList();
    list.sort((a, b) {
      if (a.state == b.state) {
        return a.fromDev.name.compareTo(b.fromDev.name);
      }
      return a.state.order.compareTo(b.state.order);
    });
    return list;
  }
}
