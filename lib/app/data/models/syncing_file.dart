import 'dart:io';

import 'package:clipshare/app/data/enums/syncing_file_state.dart';
import 'package:clipshare/app/data/models/dev_info.dart';
import 'package:clipshare/app/data/models/pending_file.dart';
import 'package:clipshare/app/data/repository/entity/tables/device.dart';
import 'package:clipshare/app/services/syncing_file_progress_service.dart';
import 'package:clipshare/app/utils/extensions/time_extension.dart';
import 'package:clipshare/app/utils/log.dart';
import 'package:get/get.dart';

/// 发送重发回调：由创建发送记录的调用方提供，重发时用它重新发起一次传输。
typedef SyncRetryCallback = Future<void> Function();

class SyncingFile {
  static const tag = "SyncingFile";
  final Device fromDev;
  final int totalSize;
  int _lastFlushBytes = 0;
  int _savedBytes;
  DateTime _startTime = DateTime.now();
  final String filePath;
  final IOSink? _sink;
  final bool isSender;
  double speed = 0.0;
  final String _fileStartTime;
  SyncingFileState _state;

  /// 进度列表中的唯一键。发送记录使用它而非 filePath，避免同一文件
  /// 发给多个设备或重发时相互覆盖。
  String? _recordKey;
  String? _error;
  SyncRetryCallback? _onRetry;
  List<PendingFile>? _retryFiles;
  Device? _retryDevice;

  /// 存储中转重发上下文：重启后据此重建重发回调。
  DevInfo? _retryTarget;
  Map<String, dynamic>? _retryData;

  SyncingFileState get state => _state;
  String? get error => _error;
  List<PendingFile>? get retryFiles => _retryFiles;
  Device? get retryDevice => _retryDevice;
  DevInfo? get retryTarget => _retryTarget;
  Map<String, dynamic>? get retryData => _retryData;
  bool get canRetry => isSender && _onRetry != null;

  void setError(String? message) {
    _error = message;
  }

  void setRetry(SyncRetryCallback callback) {
    _onRetry = callback;
  }

  /// 发送失败：记录错误信息并置为 error 状态，使卡片显示失败原因并可重发。
  void markSendFailed(String message) {
    _error = message;
    setState(SyncingFileState.error);
  }

  void setRetryContext({
    required List<PendingFile> files,
    required Device device,
  }) {
    _retryFiles = files;
    _retryDevice = device;
  }

  /// 绑定存储中转的重发上下文（目标设备 + 原始消息体），用于重启后重建重发。
  void setRetryRelay({
    required DevInfo target,
    required Map<String, dynamic> data,
  }) {
    _retryTarget = target;
    _retryData = data;
  }

  /// 重启后标记中断：传输进程已丢失，置为失败以便展示与重发。
  void markInterrupted(String message) {
    _error = message;
    _state = SyncingFileState.error;
  }

  Future<void> retry() async {
    final callback = _onRetry;
    if (callback == null) return;
    await callback();
  }

  void Function(bool done)? onClose;

  SyncingFile({
    required this.totalSize,
    required this.filePath,
    required this.fromDev,
    IOSink? sink,
    required this.isSender,
    startTime,
    String? recordKey,
    int savedBytes = 0,
    String? error,
    SyncingFileState? initialState,
    this.onClose,
  }) : _sink = sink,
       _recordKey = recordKey,
       _savedBytes = savedBytes,
       _error = error,
       _state = initialState ?? SyncingFileState.wait,
       assert(totalSize >= 0),
       assert((!isSender && sink == null) || (sink != null || isSender)),
       _fileStartTime = startTime ?? DateTime.now().format("yyyy-MM-dd HH:mm:ss");

  /// 进度列表中的唯一键，默认回退到 filePath。
  String get recordKey => _recordKey ?? filePath;

  String get startTime => _fileStartTime;

  int get lessTime => speed == 0 ? -1 : (totalSize - _savedBytes) ~/ speed;

  void addBytes(List<int> bytes) {
    if (_state == SyncingFileState.error) {
      return;
    }
    final syncingFileService = Get.find<SyncingFileProgressService>();
    if (_state != SyncingFileState.syncing) {
      _state = SyncingFileState.syncing;
      syncingFileService.updateSyncingFile(this);
    }
    if (!isSender) {
      try {
        _sink!.add(bytes);
        // await _sink.flush();
      } catch (err, stack) {
        logger.error(tag, "$filePath sync error. $err $stack");
        _error = err.toString();
        _state = SyncingFileState.error;
        syncingFileService.updateSyncingFile(this);
        return;
      }
    }
    final len = bytes.length;
    updateProgress(savedBytes + len);
  }

  void updateProgress(int newProgress) {
    final syncingFileService = Get.find<SyncingFileProgressService>();
    _savedBytes = newProgress;
    final now = DateTime.now();
    final offsetSeconds = now.difference(_startTime).inSeconds;
    final offsetMs = now.difference(_startTime).inMilliseconds;
    if (_savedBytes == totalSize || offsetSeconds >= 1) {
      _startTime = now;
      int offsetBytes = _savedBytes - _lastFlushBytes;
      speed = offsetBytes / (offsetMs / 1000);
      _lastFlushBytes = _savedBytes;
      syncingFileService.updateSyncingFile(this);
    }
  }

  int get savedBytes => _savedBytes;

  void setState(SyncingFileState state) {
    assert(isSender);
    _state = state;
    final syncingFileService = Get.find<SyncingFileProgressService>();
    syncingFileService.updateSyncingFile(this);
  }

  void close(bool done) {
    if (done) {
      _state = SyncingFileState.done;
    } else {
      _state = SyncingFileState.error;
    }
    final syncingFileService = Get.find<SyncingFileProgressService>();
    syncingFileService.updateSyncingFile(this);
    _sink?.close();
    onClose?.call(done);
  }

  Map<String, dynamic> toJson() {
    return {
      "recordKey": recordKey,
      "filePath": filePath,
      "totalSize": totalSize,
      "savedBytes": _savedBytes,
      "isSender": isSender,
      "state": _state.name,
      "error": _error,
      "startTime": _fileStartTime,
      "device": fromDev.toJson(),
      if (_retryFiles != null)
        "retryFiles": [for (final f in _retryFiles!) f.toJson()],
      if (_retryDevice != null) "retryDevice": _retryDevice!.toJson(),
      if (_retryTarget != null) "retryTarget": _retryTarget!.toJson(),
      if (_retryData != null) "retryData": _retryData,
    };
  }

  factory SyncingFile.fromJson(Map<String, dynamic> map) {
    final record = SyncingFile(
      totalSize: map["totalSize"] as int,
      filePath: map["filePath"] as String,
      fromDev: Device.fromJson(Map<String, dynamic>.from(map["device"] as Map)),
      isSender: map["isSender"] as bool,
      startTime: map["startTime"] as String?,
      recordKey: map["recordKey"] as String?,
      savedBytes: map["savedBytes"] as int? ?? 0,
      error: map["error"] as String?,
      initialState: SyncingFileState.values.byName(map["state"] as String),
    );
    final files = (map["retryFiles"] as List?)
        ?.map((e) => PendingFile.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final retryDevice = map["retryDevice"] != null
        ? Device.fromJson(
            Map<String, dynamic>.from(map["retryDevice"] as Map))
        : null;
    if (files != null && retryDevice != null) {
      record.setRetryContext(files: files, device: retryDevice);
    }
    if (map["retryTarget"] != null && map["retryData"] != null) {
      record.setRetryRelay(
        target: DevInfo.fromJson(
            Map<String, dynamic>.from(map["retryTarget"] as Map)),
        data: Map<String, dynamic>.from(map["retryData"] as Map),
      );
    }
    return record;
  }
}
