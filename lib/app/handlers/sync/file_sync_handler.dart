import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clipshare/app/data/enums/forward_msg_type.dart';
import 'package:clipshare/app/data/enums/history_content_type.dart';
import 'package:clipshare/app/data/enums/msg_type.dart';
import 'package:clipshare/app/data/enums/notification_payload_type.dart';
import 'package:clipshare/app/data/enums/syncing_file_state.dart';
import 'package:clipshare/app/data/enums/transport_protocol.dart';
import 'package:clipshare/app/data/enums/translation_key.dart';
import 'package:clipshare/app/data/models/dev_info.dart';
import 'package:clipshare/app/data/models/notification_payload.dart';
import 'package:clipshare/app/data/models/pending_file.dart';
import 'package:clipshare/app/data/models/syncing_file.dart';
import 'package:clipshare/app/data/repository/entity/tables/device.dart';
import 'package:clipshare/app/data/repository/entity/tables/history.dart';
import 'package:clipshare/app/handlers/socket/forward_socket_client.dart';
import 'package:clipshare/app/handlers/socket/secure_socket_client.dart';
import 'package:clipshare/app/modules/device_module/device_controller.dart';
import 'package:clipshare/app/modules/history_module/history_controller.dart';
import 'package:clipshare/app/services/channels/android_channel.dart';
import 'package:clipshare/app/services/config_service.dart';
import 'package:clipshare/app/services/db_service.dart';
import 'package:clipshare/app/services/transport/socket_service.dart';
import 'package:clipshare/app/services/syncing_file_progress_service.dart';
import 'package:clipshare/app/services/transport/storage_service.dart';
import 'package:clipshare/app/utils/extensions/device_extension.dart';
import 'package:clipshare/app/utils/extensions/file_extension.dart';
import 'package:clipshare/app/utils/extensions/number_extension.dart';
import 'package:clipshare/app/utils/extensions/platform_extension.dart';
import 'package:clipshare/app/utils/extensions/time_extension.dart';
import 'package:clipshare/app/utils/file_util.dart';
import 'package:clipshare/app/utils/global.dart';
import 'package:clipshare/app/utils/notify_util.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:uri_file_reader/uri_file_reader.dart';

import '../../utils/log.dart';

class FileSyncHandler {
  static const tag = "FileSyncer";
  static const _receivedFileNotifyKeyPrefix = 'receive-file';
  final appConfig = Get.find<ConfigService>();
  final dbService = Get.find<DbService>();
  final sktService = Get.find<SocketService>();
  final syncingFileService = Get.find<SyncingFileProgressService>();
  ServerSocket? _server;
  Socket? _forwardSkt;
  late final int _fileId;
  bool hasClient = false;
  File? _file;
  PendingFile pendingFile;
  late final void Function() _onDone;
  late final bool isUri;
  late final Device _device;
  late final SyncingFile _sendRecord;

  FileSyncHandler._private({
    required this.pendingFile,
    required void Function(FileSyncHandler) onReady,
    required void Function() onDone,
    required Device device,
    bool useForward = false,
    String? targetDevId,
  }) {
    _fileId = appConfig.snowflake.nextId();
    _onDone = onDone;
    _device = device;
    isUri = pendingFile.isUri;
    if (!isUri) {
      final path = pendingFile.filePath;
      _file = File(path);
      if (!_file!.existsSync()) {
        throw Exception("file not found: $path");
      }
    }
    // 发送记录在传输开始前就创建，保证“空发送”（对方未连接/离线）也能留下记录并可重发。
    _sendRecord = _createSendRecord();
    syncingFileService.updateSyncingFile(_sendRecord);
    try {
      _startTransfer(useForward: useForward, targetDevId: targetDevId, onReady: onReady);
    } catch (err) {
      _sendRecord.setError(err.toString());
      _sendRecord.setState(SyncingFileState.error);
    }
  }

  void _startTransfer({
    required bool useForward,
    required String? targetDevId,
    required void Function(FileSyncHandler) onReady,
  }) {
    if (useForward) {
      //检查中转设置
      var host = sktService.forwardServerHost;
      var port = sktService.forwardServerPort;
      var forwardEnabled = appConfig.enableForward;
      if (!forwardEnabled || host == null || port == null) {
        throw Exception("Forwarding service not enabled.");
      }
      //连接中转服务器
      Socket.connect(host, port).then((skt) async {
        final fileName = isUri ? pendingFile.fileName : _file!.fileName;
        final size = isUri ? pendingFile.size : await _file!.length();
        _forwardSkt = skt;
        var baseMsg = ForwardSocketClient.baseMsg;
        //向中转服务器发送基本信息
        final payload = utf8.encode(
          json.encode(
            baseMsg..addAll({
              "fileName": fileName,
              "size": size.toString(),
              "fileId": _fileId.toString(),
              "target": targetDevId!,
              "connType": ForwardConnType.sendFile.name,
              "userId": appConfig.userId.toString(),
            }),
          ),
        );
        final msgSize = payload.length;
        final header = SecureSocketClient.createPacketHeader(
          msgSize,
          msgSize,
          1,
          1,
        );
        // 组合头部和载荷
        Uint8List packet = Uint8List(header.length + payload.length);
        // 写入头部
        packet.setAll(0, header);
        // 写入载荷
        packet.setAll(header.length, payload);
        //写入数据
        skt.add(packet);
      });
      //告知 SocketService
      sktService.addSendFileRecordByForward(this, _fileId);
      //延时检测是否有客户端连接，超时取消发送
      _delayedClientCheck(() {
        _onDone();
        sktService.removeSendFileRecordByForward(this, _fileId, targetDevId!);
      });
    } else {
      ServerSocket.bind(InternetAddress.anyIPv4, 0).then((server) {
        _server = server;
        onReady(this);
        _server!.listen((client) async {
          hasClient = true;
          try {
            //向客户端发送文件
            sendFile2Socket(client);
          } catch (err, stack) {
            logger.error(tag, "$err,$stack");
            hasClient = false;
            client.close();
            _server?.close();
          }
        });
        _delayedClientCheck(_onDone);
      });
    }
  }

  ///当文件接收方连接了中转服务器后由 SocketService 调用该方法通知发送端开始发送
  void onForwardReceiverConnected() {
    sktService.removeSendFileRecordByForward(this, _fileId, null);
    hasClient = true;
    try {
      //向 中转服务器 发送文件
      sendFile2Socket(_forwardSkt!);
    } catch (err, stack) {
      logger.error(tag, "$err,$stack");
    }
  }

  /// 创建（或重建）本次发送的进度记录，并绑定重发上下文。
  SyncingFile _createSendRecord() {
    final filePath = isUri ? pendingFile.filePath : _file!.normalizePath;
    final fileSize = isUri ? pendingFile.size! : _file!.lengthSync();
    final record = SyncingFile(
      totalSize: fileSize,
      filePath: filePath,
      fromDev: _device,
      isSender: true,
      startTime: DateTime.now().format(),
      recordKey: "${_fileId}_$filePath",
    );
    record.setRetryContext(files: [pendingFile], device: _device);
    record.setRetry(() async {
      // 重发：移除旧记录后重新发起一次发送（会创建新的进度记录）。
      syncingFileService.removeSyncingFile(record.recordKey);
      FileSyncHandler.sendFiles(
        devices: [_device],
        files: [pendingFile],
      );
    });
    return record;
  }

  ///向 socket 发送文件
  Future<void> sendFile2Socket(Socket client) async {
    DateTime start = DateTime.now();
    final filePath = isUri ? pendingFile.filePath : _file!.normalizePath;
    final fileSize = isUri ? pendingFile.size! : _file!.lengthSync();
    final fileName = isUri ? pendingFile.fileName : _file!.fileName;
    final syncingFile = _sendRecord;
    // 手动停止时销毁底层 socket，避免连接泄漏（记录本身由停止按钮移除）。
    syncingFile.onClose = (done) {
      if (!done) {
        client.destroy();
      }
    };
    syncingFileService.updateSyncingFile(syncingFile);
    Stream<List<int>> stream;
    if (isUri) {
      final nullableStream = await uriFileReader.readFileAsBytesStream(pendingFile.filePath);
      if (nullableStream == null) {
        Global.showSnackBarWarn(text: TranslationKey.failedToLoad.tr);
        throw TranslationKey.failedToLoad.tr;
      }
      stream = nullableStream.transform(
        StreamTransformer<Uint8List, List<int>>.fromHandlers(
          handleData: (data, sink) {
            syncingFile.addBytes(data);
            sink.add(data);
          },
        ),
      );
    } else {
      stream = _file!.openRead().transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (data, sink) {
            syncingFile.addBytes(data);
            sink.add(data);
          },
        ),
      );
    }
    syncingFile.setState(SyncingFileState.syncing);
    client
        .addStream(stream)
        .then((value) {
          var path = filePath;
          try {
            path = Uri.decodeComponent(filePath);
          } catch (err) {
            //ignored
          }
          var history = History(
            id: _fileId,
            uid: appConfig.userId,
            devId: appConfig.devInfo.guid,
            time: start.toString(),
            content: path,
            type: HistoryContentType.file.value,
            size: fileSize,
            sync: true,
          );
          final historyController = Get.find<HistoryController>();
          historyController.addData(history, null, false);
          syncingFile.setState(SyncingFileState.done);
        })
        .catchError((err, stack) {
          syncingFile.setError(err.toString());
          syncingFile.setState(SyncingFileState.error);
          logger.error(tag, "send file failed: $filePath. $err $stack");
        })
        .whenComplete(() {
          logger.info(tag, "send file($fileName) completed");
          client.close();
          _server?.close();
          _onDone();
        });
  }

  ///在一定时间后检查是否有客户端连接，若无客户端则关闭服务
  void _delayedClientCheck(void Function() onDone) {
    Future.delayed(5.s, () {
      if (hasClient) return;
      logger.info(tag, "No client connection for more than 5 seconds");
      // 空发送：对方未连接/离线，标记为失败并允许在进度界面重发。
      _sendRecord.setError(TranslationKey.sendFileNoReceiver.tr);
      _sendRecord.setState(SyncingFileState.error);
      _server?.close();
      _forwardSkt?.close();
      onDone();
    });
  }

  /// 桌面端/安卓端按配置在接收完成后发送通知；桌面端点击通知直接打开文件，安卓端点击打开应用（正文提示"点击查看"）。
  static Future<void> _notifyReceivedFileIfNeeded({
    required ConfigService appConfig,
    required File file,
    required int fileId,
  }) async {
    if (!(PlatformExt.isDesktop || Platform.isAndroid) || !appConfig.notifyOnReceivedFile) {
      return;
    }
    await NotifyUtil.notify(
      title: file.fileName,
      content: Platform.isAndroid
          ? TranslationKey.receivedFileNotifyTapToView.tr
          : TranslationKey.preferenceSettingsNotifyOnReceivedFileDesc.tr,
      key: '$_receivedFileNotifyKeyPrefix-$fileId',
      payload: NotificationPayload(
        type: NotificationPayloadType.openFile,
        data: {
          NotificationPayload.filePathKey: file.normalizePath,
        },
      ),
    );
  }

  //region 静态方法接收和发送文件

  ///给多个设备发送多个文件
  ///[devices] 发送的设备列表
  ///[files] 发送的文件列表
  ///[i] 发送第几个文件
  static void sendFiles({
    required List<Device> devices,
    required List<PendingFile> files,
    int i = 0,
  }) {
    if (i >= devices.length) {
      return;
    }
    //给每个设备发送文件
    _sendDevFiles(
      device: devices[i],
      paths: files,
      //发完一个设备后给下一个设备发送
      onDone: () => sendFiles(
        devices: devices,
        files: files,
        i: i + 1,
      ),
    );
  }

  /// 中转发送记录的重发：按设备当前连接状态重新选择传输路径。
  /// 若目标设备当前已处于局域网 socket 直连（direct），则改走 socket 直发重发，
  /// 避免回到局域网后仍向公网 WebDAV 地址上传大文件（NAT 回环易被重置）；
  /// 否则维持原存储中转路径。
  static Future<void> retryRelayFile({
    required DevInfo target,
    required Map<String, dynamic> data,
  }) async {
    // 重发前校验：本地文件已被删除时，重建一条失败记录提示用户，
    // 避免旧记录已被移除后重发静默失败、进度页什么都不剩。
    final retryFilePath = data["filePath"] as String? ?? "";
    final retryIsUri = data["isUri"] as bool? ?? false;
    if (!retryIsUri &&
        retryFilePath.isNotEmpty &&
        !File(retryFilePath).existsSync()) {
      logger.warn(tag, "retry relay file missing: $retryFilePath");
      Get.find<SyncingFileProgressService>().updateSyncingFile(
        SyncingFile(
          totalSize: data["size"] as int? ?? 0,
          filePath: retryFilePath,
          fromDev: Get.find<ConfigService>().device,
          isSender: true,
          error: TranslationKey.noSuchFile.tr,
          initialState: SyncingFileState.error,
        ),
      );
      return;
    }
    final devController = Get.find<DeviceController>();
    final card = [...devController.pairedList, ...devController.discoverList]
        .firstWhereOrNull((item) => item.dev?.guid == target.guid && item.isConnected);
    final device = card?.dev;
    if (device != null && card!.protocol == TransportProtocol.direct) {
      logger.info(tag, "retry relay file: ${device.devName} now direct-connected, resend via socket");
      final pending = PendingFile(
        isDirectory: false,
        filePath: data["filePath"] as String,
        directories: const [],
        isUri: data["isUri"] as bool? ?? false,
        fileName: data["fileName"] as String?,
        size: data["size"] as int?,
      );
      sendFiles(devices: [device], files: [pending]);
      return;
    }
    logger.info(tag, "retry relay file: ${target.name} not directly reachable, resend via storage relay");
    await Get.find<StorageService>().sendData(target, MsgType.file, Map<String, dynamic>.from(data));
  }

  ///给设备发送多个文件
  ///[device] 发送的设备
  ///[paths] 发送的文件列表
  ///[onDone] 发送完成事件
  ///[i] 发送第几个文件
  static void _sendDevFiles({
    required Device device,
    required List<PendingFile> paths,
    required void Function() onDone,
    int i = 0,
  }) {
    if (i >= paths.length) {
      onDone();
      return;
    }
    _sendFile(
      device: device,
      pendingFile: paths[i],
      //发完一个文件后给设备发送下一个文件
      onDone: () => _sendDevFiles(
        device: device,
        paths: paths,
        onDone: onDone,
        i: i + 1,
      ),
    );
  }

  ///发送文件
  ///[device] 发送的设备
  ///[pendingFile] 发送的文件地址
  static void _sendFile({
    required Device device,
    required PendingFile pendingFile,
    required void Function() onDone,
  }) async {
    int totalSize;
    String fileName;
    if (pendingFile.isUri) {
      totalSize = pendingFile.size!;
      fileName = pendingFile.fileName!;
    } else {
      final file = File(pendingFile.filePath);
      totalSize = await file.length();
      fileName = file.fileName;
    }
    //如果存在多级文件夹就拼接上文件夹
    if (pendingFile.directories.isNotEmpty) {
      fileName = "${pendingFile.directories.join("/")}/$fileName";
    }
    if (device.isUseStorage) {
      final storageService = Get.find<StorageService>();
      final appConfig = Get.find<ConfigService>();
      // 存储中转也必须等待发送结束后再推进队列，否则多文件发送会卡在当前设备。
      await storageService.sendData(DevInfo.fromDevice(device), MsgType.file, {
        "fileId": appConfig.snowflake.nextId(),
        "filePath": pendingFile.filePath,
        "fileName": fileName,
        "isUri": pendingFile.isUri,
        "size": totalSize,
      });
      onDone();
    } else {
      final sktService = Get.find<SocketService>();
      final useForward = sktService.isUseForward(device.guid);
      FileSyncHandler._private(
        pendingFile: pendingFile,
        device: device,
        useForward: useForward,
        targetDevId: useForward ? device.guid : null,
        onReady: (syncer) async {
          device.sendData(MsgType.file, {
            "fileName": fileName,
            "size": totalSize,
            "port": syncer._server?.port,
            "fileId": syncer._fileId,
          });
        },
        onDone: onDone,
      );
    }
  }

  static Future<void> receiveFile({
    required String ip,
    required int port,
    required int size,
    required String fileName,
    required String devId,
    required int userId,
    required int fileId,
    bool isForward = false,
    String? targetId,
  }) async {
    //中转模式下targetId不能为null
    assert(!isForward || targetId != null);
    final dbService = Get.find<DbService>();
    final appConfig = Get.find<ConfigService>();
    Device? dev = await dbService.deviceDao.getById(devId, appConfig.userId);
    if (dev == null) {
      logger.error(tag, "dev:$devId not found");
      return;
    }
    var socket = await Socket.connect(ip, port);
    final safeFileName = FileUtil.sanitizeReceivedFileName(fileName);
    String filePath = "${appConfig.fileStorePath}/$safeFileName";
    File file = File(filePath);
    logger.debug(tag, "receive file $filePath");
    final dir = file.parent;
    //如果父级文件夹不存在则创建
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    ///文件存在处理策略
    while (file.existsSync()) {
      //如果文件存在，给文件加后缀
      final seqName = file.buildDuplicateSeqName();
      filePath = "${appConfig.fileStorePath}/$seqName";
      file = File(filePath);
    }
    final syncingFileService = Get.find<SyncingFileProgressService>();
    final syncingFile = SyncingFile(
      totalSize: size,
      filePath: filePath,
      fromDev: dev,
      sink: file.openWrite(),
      isSender: false,
      startTime: DateTime.now().format("yyyy-MM-dd HH:mm:ss"),
      onClose: (done) {
        if (done) {
          return;
        }
        socket.destroy();
        syncingFileService.removeSyncingFile(filePath);
      },
    );
    syncingFileService.updateSyncingFile(syncingFile);
    var start = DateTime.now();
    if (isForward) {
      //告知发送方接收方已经连接
      Map<String, String> data = {
        "connType": ForwardConnType.recFile.name,
        "target": targetId!,
        "fileId": fileId.toString(),
        "self": appConfig.device.guid,
      };
      final payload = utf8.encode(json.encode(data));
      final msgSize = payload.length;
      final header = SecureSocketClient.createPacketHeader(
        msgSize,
        msgSize,
        1,
        1,
      );
      // 组合头部和载荷
      Uint8List packet = Uint8List(header.length + payload.length);
      // 写入头部
      packet.setAll(0, header);
      // 写入载荷
      packet.setAll(header.length, payload);
      //写入数据
      socket.add(packet);
    }
    socket.listen(
      (bytes) {
        syncingFile.addBytes(bytes);
      },
      onError: (err, stack) {
        logger.error(tag, "receive file failed. $err $stack");
        file.delete();
        syncingFile.close(false);
      },
      cancelOnError: true,
      onDone: () async {
        // 对端发送完成后会主动关闭写端，本端必须立即释放 Socket，避免连接停留在 CLOSE_WAIT。
        socket.destroy();
        var end = DateTime.now();
        int offset = max(end.difference(start).inSeconds, 1);
        int speed = size ~/ offset;
        logger.info(
          tag,
          "onDone $offset seconds, size: ${size.sizeStr}, speed: ${speed.sizeStr}/s",
        );
        var history = History(
          id: fileId,
          uid: userId,
          devId: devId,
          time: start.toString(),
          content: filePath,
          type: HistoryContentType.file.value,
          size: size,
          sync: true,
        );
        final historyController = Get.find<HistoryController>();
        try {
          await historyController.addData(history, null, false);
        } finally {
          syncingFile.close(true);
        }
        await _notifyReceivedFileIfNeeded(
          appConfig: appConfig,
          file: file,
          fileId: fileId,
        );
        if (file.isMediaFile) {
          //媒体文件，刷新媒体库
          if (Platform.isAndroid) {
            var androidChannelService = Get.find<AndroidChannelService>();
            androidChannelService.notifyMediaScan(filePath);
          }
        }
      },
    );
  }

  //endregion
}
