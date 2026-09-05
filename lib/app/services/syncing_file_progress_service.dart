import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipshare/app/data/enums/msg_type.dart';
import 'package:clipshare/app/data/enums/syncing_file_state.dart';
import 'package:clipshare/app/data/enums/translation_key.dart';
import 'package:clipshare/app/data/models/syncing_file.dart';
import 'package:clipshare/app/handlers/sync/file_sync_handler.dart';
import 'package:clipshare/app/modules/sync_file_module/sync_file_controller.dart';
import 'package:clipshare/app/services/config_service.dart';
import 'package:clipshare/app/services/transport/storage_service.dart';
import 'package:clipshare/app/utils/log.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

class SyncingFileProgressService extends GetxService {
  static const tag = "SyncingFileProgress";

  /// 以 [SyncingFile.recordKey] 为键。发送记录使用唯一键，
  /// 因此同一文件发给多个设备、或失败后重发，都不会相互覆盖。
  final _syncingFilesMap = <String, SyncingFile>{}.obs;

  Timer? _saveTimer;

  Future<SyncingFileProgressService> init() async {
    // 翻译在 GetMaterialApp 构建后才可用，恢复延后到首帧，避免中断提示存成原始 key。
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
    return this;
  }

  File get _storeFile =>
      File("${Get.find<ConfigService>().documentsPath}syncing_records.json");

  void updateSyncingFile(SyncingFile syncingFile) {
    _syncingFilesMap[syncingFile.recordKey] = syncingFile;
    _scheduleSave();
    _postHandle(syncingFile);
  }

  void removeSyncingFile(String recordKey) {
    if (!_syncingFilesMap.containsKey(recordKey)) return;
    var syncingFile = _syncingFilesMap[recordKey];
    _syncingFilesMap.remove(recordKey);
    _scheduleSave();
    _postHandle(syncingFile!);
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
        // 与历史列表一致：新记录排在上面
        final byTime = b.startTime.compareTo(a.startTime);
        if (byTime != 0) {
          return byTime;
        }
        return a.fromDev.name.compareTo(b.fromDev.name);
      }
      return a.state.order.compareTo(b.state.order);
    });
    return list;
  }

  //region 持久化

  /// 启动时恢复上次的发送/接收记录。进行中的传输已随进程结束，
  /// 恢复为失败状态；发送记录若带有重发上下文则重建重发回调。
  void _restore() {
    try {
      final file = _storeFile;
      if (!file.existsSync()) return;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return;
      for (final item in decoded) {
        final record =
            SyncingFile.fromJson(Map<String, dynamic>.from(item as Map));
        _normalizeRestored(record);
        _syncingFilesMap[record.recordKey] = record;
      }
    } catch (err) {
      logger.error(tag, "restore syncing records failed: $err");
    }
  }

  void _normalizeRestored(SyncingFile record) {
    final interrupted = record.state == SyncingFileState.syncing ||
        record.state == SyncingFileState.wait;
    if (interrupted) {
      if (!record.isSender) {
        // 中断的接收文件不完整，与运行期接收失败的行为保持一致：删除。
        try {
          File(record.filePath).deleteSync();
        } catch (_) {}
      }
      record.markInterrupted(TranslationKey.recordInterrupted.tr);
    }
    if (record.isSender) {
      _bindRestoredRetry(record);
    }
  }

  void _bindRestoredRetry(SyncingFile record) {
    final files = record.retryFiles;
    final device = record.retryDevice;
    if (files != null && files.isNotEmpty && device != null) {
      // socket 直发路径：重发时重新发起一次发送。
      record.setRetry(() async {
        removeSyncingFile(record.recordKey);
        FileSyncHandler.sendFiles(
          devices: [device],
          files: files,
        );
      });
      return;
    }
    final target = record.retryTarget;
    final data = record.retryData;
    if (target != null && data != null) {
      // 存储中转路径：重发时重新走一次中转发送。
      record.setRetry(() async {
        removeSyncingFile(record.recordKey);
        try {
          await Get.find<StorageService>()
              .sendData(target, MsgType.file, Map<String, dynamic>.from(data));
        } catch (err) {
          logger.error(tag, "retry relay send failed: $err");
        }
      });
    }
  }

  /// 进度更新频繁，落盘做防抖；状态变化最迟 500ms 后写入。
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _save);
  }

  void _save() {
    try {
      final file = _storeFile;
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      final list = _syncingFilesMap.values.map((e) => e.toJson()).toList();
      file.writeAsStringSync(jsonEncode(list));
    } catch (err) {
      logger.error(tag, "save syncing records failed: $err");
    }
  }

  @override
  void onClose() {
    _saveTimer?.cancel();
    _save();
    super.onClose();
  }

  //endregion
}
