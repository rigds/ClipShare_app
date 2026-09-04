import 'dart:io';

import 'package:clipshare/app/data/enums/syncing_file_state.dart';
import 'package:clipshare/app/data/enums/transport_protocol.dart';
import 'package:clipshare/app/data/models/pending_file.dart';
import 'package:clipshare/app/data/repository/entity/tables/device.dart';
import 'package:clipshare/app/services/syncing_file_progress_service.dart';
import 'package:clipshare/app/utils/extensions/time_extension.dart';
import 'package:clipshare/app/utils/log.dart';
import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';

/// 发送重发回调：由创建发送记录的调用方提供，重发时用它重新发起一次传输。
typedef SyncRetryCallback = Future<void> Function();

class SyncingFile {
  static const tag = "SyncingFile";
  final Device fromDev;
  final int totalSize;
  int _lastFlushBytes = 0;
  int _savedBytes = 0;
  DateTime _startTime = DateTime.now();
  final BuildContext context;
  final String filePath;
  final IOSink? _sink;
  final bool isSender;
  double speed = 0.0;
  final String _fileStartTime;
  SyncingFileState _state = SyncingFileState.wait;

  /// 进度列表中的唯一键。发送记录使用它而非 filePath，避免同一文件
  /// 发给多个设备或重发时相互覆盖。
  String? _recordKey;
  String? _error;
  SyncRetryCallback? _onRetry;
  List<PendingFile>? _retryFiles;
  Device? _retryDevice;

  SyncingFileState get state => _state;
  String? get error => _error;
  List<PendingFile>? get retryFiles => _retryFiles;
  Device? get retryDevice => _retryDevice;
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

  /// 重发前重置进度，使卡片从 0% 重新计数。
  void resetForRetry() {
    _savedBytes = 0;
    _lastFlushBytes = 0;
    _startTime = DateTime.now();
    speed = 0.0;
    _error = null;
    _state = SyncingFileState.wait;
  }

  Future<void> retry() async {
    final callback = _onRetry;
    if (callback == null) return;
    await callback();
  }

  void Function(bool done)? onClose;

  SyncingFile({
    required this.totalSize,
    required this.context,
    required this.filePath,
    required this.fromDev,
    IOSink? sink,
    required this.isSender,
    startTime,
    String? recordKey,
    this.onClose,
  }) : _sink = sink,
       _recordKey = recordKey,
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
}
