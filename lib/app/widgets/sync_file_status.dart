import 'dart:async';
import 'dart:io';

import 'package:clipshare/app/data/enums/syncing_file_state.dart';
import 'package:clipshare/app/data/enums/translation_key.dart';
import 'package:clipshare/app/data/models/syncing_file.dart';
import 'package:clipshare/app/data/repository/entity/tables/device.dart';
import 'package:clipshare/app/data/repository/entity/tables/history.dart';
import 'package:clipshare/app/services/config_service.dart';
import 'package:clipshare/app/services/device_service.dart';
import 'package:clipshare/app/services/syncing_file_progress_service.dart';
import 'package:clipshare/app/utils/extensions/file_extension.dart';
import 'package:clipshare/app/utils/extensions/number_extension.dart';
import 'package:clipshare/app/utils/extensions/platform_extension.dart';
import 'package:clipshare/app/utils/extensions/time_extension.dart';
import 'package:clipshare/app/utils/global.dart';
import 'package:clipshare/app/utils/log.dart';
import 'package:clipshare/app/widgets/segmented_color.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:open_file_plus/open_file_plus.dart';

class SyncFileStatus extends StatelessWidget {
  static const tag = "SyncFileStatus";
  final SyncingFile syncingFile;
  final double factor;
  final bool isLocal;
  final bool selectMode;
  final bool selected;
  final int? historyId;
  final appConfig = Get.find<ConfigService>();
  final syncingFileService = Get.find<SyncingFileProgressService>();

  SyncFileStatus({
    super.key,
    required this.syncingFile,
    required this.factor,
    this.isLocal = false,
    this.selectMode = false,
    this.selected = false,
    this.historyId,
  });

  factory SyncFileStatus.fromHistory(
    BuildContext context,
    History history,
    String selfDevId,
  ) {
    final devService = Get.find<DeviceService>();
    Device dev = devService.getById(history.devId);
    return SyncFileStatus(
      syncingFile: SyncingFile(
        totalSize: history.size,
        context: context,
        filePath: history.content,
        fromDev: dev,
        isSender: selfDevId == history.devId,
        startTime: DateTime.parse(history.time).format(),
      ),
      factor: 1,
      isLocal: true,
      historyId: history.id,
    );
  }

  SyncFileStatus copyWith({bool? selected, bool? selectMode}) {
    return SyncFileStatus(
      syncingFile: syncingFile,
      factor: factor,
      isLocal: isLocal,
      selected: selected ?? this.selected,
      selectMode: selectMode ?? this.selectMode,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(12.0),
          mouseCursor: SystemMouseCursors.basic,
          onTap: selectMode
              ? null
              : () async {
                  if (PlatformExt.isDesktop) {
                    return;
                  }
                  final file = File(syncingFile.filePath);
                  await OpenFile.open(
                    file.normalizePath,
                  );
                },
          onDoubleTap: selectMode
              ? null
              : () async {
                  if (PlatformExt.isMobile) {
                    return;
                  }
                  final file = File(syncingFile.filePath);
                  if (!file.existsSync()) {
                    Global.showSnackBarWarn(context: context, text: TranslationKey.fileNotFound.tr);
                  } else {
                    Global.showSnackBarSuc(context: context, text: TranslationKey.openingFile.tr);
                  }
                  await OpenFile.open(
                    file.normalizePath,
                  );
                },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              File(syncingFile.filePath).fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Row(
                            children: [
                              Visibility(
                                visible: isLocal,
                                child: Visibility(
                                  visible: syncingFile.fromDev.guid == appConfig.device.guid,
                                  replacement: const Icon(
                                    Icons.download,
                                    color: Colors.blue,
                                  ),
                                  child: const Icon(
                                    Icons.upload,
                                    color: Colors.green,
                                  ),
                                ),
                              ),
                              Visibility(
                                visible: isLocal && !selectMode,
                                replacement: Visibility(
                                  visible: selectMode,
                                  child: IconButton(
                                    icon: Icon(
                                      selected ? Icons.check_box : Icons.check_box_outline_blank,
                                      color: const Color(0xFF33A0E3),
                                    ),
                                    onPressed: null,
                                  ),
                                ),
                                child: Tooltip(
                                  message: TranslationKey.openFolder.tr,
                                  child: IconButton(
                                    onPressed: () async {
                                      final path = File(syncingFile.filePath).parent.normalizePath;
                                      var result = await OpenFile.open(path);
                                      logger.debug(
                                        tag,
                                        "type: ${result.type}, msg: ${result.message}",
                                      );
                                    },
                                    icon: const Icon(
                                      color: Colors.blueGrey,
                                      Icons.folder_copy_outlined,
                                    ),
                                  ),
                                ),
                              ),
                              // 传输中：停止（取消并移除记录）
                              Visibility(
                                visible: !isLocal &&
                                    (syncingFile.state == SyncingFileState.wait ||
                                        syncingFile.state == SyncingFileState.syncing),
                                child: Tooltip(
                                  message: TranslationKey.stop.tr,
                                  child: IconButton(
                                    onPressed: () async {
                                      syncingFile.close(false);
                                      syncingFileService.removeSyncingFile(
                                        syncingFile.recordKey,
                                      );
                                    },
                                    icon: const Icon(
                                      color: Colors.red,
                                      Icons.stop_circle_outlined,
                                    ),
                                  ),
                                ),
                              ),
                              // 已结束（成功/失败）：仅从进度列表移除记录
                              Visibility(
                                visible: !isLocal &&
                                    (syncingFile.state == SyncingFileState.done ||
                                        syncingFile.state == SyncingFileState.error),
                                child: Tooltip(
                                  message: TranslationKey.delete.tr,
                                  child: IconButton(
                                    onPressed: () async {
                                      syncingFileService.removeSyncingFile(
                                        syncingFile.recordKey,
                                      );
                                    },
                                    icon: const Icon(
                                      color: Colors.blueGrey,
                                      Icons.remove_circle_outline,
                                    ),
                                  ),
                                ),
                              ),
                              // 发送失败 / 空发送：提供重发按钮（点击后先弹确认框）
                              Visibility(
                                visible: !isLocal && syncingFile.canRetry,
                                child: Tooltip(
                                  message: TranslationKey.resend.tr,
                                  child: IconButton(
                                    onPressed: () {
                                      final fileName =
                                          syncingFile.filePath
                                              .split(RegExp(r'[/\\]'))
                                              .last;
                                      Global.showTipsDialog(
                                        context: Get.context!,
                                        title: TranslationKey.resend.tr,
                                        text:
                                            "${TranslationKey.resendConfirm.tr}\n"
                                            "$fileName -> ${syncingFile.fromDev.name}",
                                        showCancel: true,
                                        onOk: () {
                                          unawaited(syncingFile.retry());
                                        },
                                      );
                                    },
                                    icon: const Icon(
                                      color: Colors.orange,
                                      Icons.refresh,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(
                        height: 10,
                      ),
                      TweenAnimationBuilder(
                        tween: Tween<double>(
                          begin: isLocal ? 1 : 0.0,
                          end: isLocal ? 1 : factor,
                        ),
                        duration: 300.ms,
                        builder: (context, value, child) {
                          return Stack(
                            children: [
                              LinearProgressIndicator(
                                value: value,
                                minHeight: 20,
                                color: syncingFile.state == SyncingFileState.error ? Colors.red : null,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 5),
                                child: SizedBox(
                                  height: 20,
                                  child: SegmentedTextColorContainer(
                                    segmentedColor: Colors.white,
                                    widthFactor: value,
                                    defaultTextStyle: const TextStyle(color: Colors.black),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              syncingFile.totalSize.sizeStr,
                                            ),
                                            Visibility(
                                              visible: !isLocal,
                                              child: Row(
                                                children: [
                                                  Container(
                                                    width: 1,
                                                    height: 10,
                                                    margin: const EdgeInsets.only(
                                                      left: 5,
                                                      right: 5,
                                                    ),
                                                    color: Colors.grey,
                                                  ),
                                                  Visibility(
                                                    visible: !isLocal,
                                                    child: Text(
                                                      "${syncingFile.speed.sizeStr}/s",
                                                    ),
                                                  ),
                                                  Container(
                                                    width: 1,
                                                    height: 10,
                                                    margin: const EdgeInsets.only(
                                                      left: 5,
                                                      right: 5,
                                                    ),
                                                    color: Colors.grey,
                                                  ),
                                                  Text(
                                                    syncingFile.lessTime.to24HFormatStr,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        Visibility(
                                          visible: !isLocal,
                                          child: Tooltip(
                                            message: syncingFile.error ?? TranslationKey.failed.tr,
                                            child: Text(
                                              syncingFile.state == SyncingFileState.error ? TranslationKey.failed.tr : "${(factor * 10000).round() / 100}%",
                                            ),
                                          ),
                                        ),
                                        Row(
                                          children: [
                                            Text(
                                              DateTime.parse(
                                                syncingFile.startTime,
                                              ).simpleStr,
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
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
