import 'dart:io';

import 'package:clipshare/app/utils/double_tap_wrapper.dart';
import 'package:clipshare/app/utils/extensions/history_data_extension.dart';
import 'package:clipshare/app/utils/extensions/number_extension.dart';
import 'package:clipshare/app/widgets/clip/clip_native_drag_item_wrapper.dart';
import 'package:clipshare/app/data/enums/module.dart';
import 'package:clipshare/app/data/enums/op_method.dart';
import 'package:clipshare/app/data/enums/translation_key.dart';
import 'package:clipshare/app/data/models/clip_data.dart';
import 'package:clipshare/app/data/repository/entity/tables/operation_record.dart';
import 'package:clipshare/app/modules/home_module/home_controller.dart';
import 'package:clipshare/app/modules/views/clipboard_detail_drawer.dart';
import 'package:clipshare/app/modules/views/preview_page.dart';
import 'package:clipshare/app/modules/views/tag_edit_page.dart';
import 'package:clipshare/app/services/channels/android_channel.dart';
import 'package:clipshare/app/services/channels/clip_channel.dart';
import 'package:clipshare/app/services/clipboard_source_service.dart';
import 'package:clipshare/app/services/config_service.dart';
import 'package:clipshare/app/services/db_service.dart';
import 'package:clipshare/app/utils/extensions/file_extension.dart';
import 'package:clipshare/app/utils/extensions/platform_extension.dart';
import 'package:clipshare/app/widgets/clip/clip_simple_data_content.dart';
import 'package:clipshare/app/widgets/clip/clip_simple_data_footer.dart';
import 'package:clipshare/app/widgets/clip/clip_simple_data_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:get/get.dart';
import 'package:open_file_plus/open_file_plus.dart';

class ClipDataCard extends StatefulWidget {
  final ClipData clip;
  final void Function()? onTap;
  final void Function()? onLongPress;
  final void Function()? onDoubleTap;
  final void Function()? onToggleSelected;
  final void Function()? onMoreActionsTap;
  final void Function() onUpdate;
  final void Function(ClipData item) onRemoveClicked;
  final bool routeToSearchOnClickChip;
  final bool imageMode;
  final bool selectMode;
  final bool selected;

  const ClipDataCard({
    required this.clip,
    required this.onUpdate,
    required this.onRemoveClicked,
    super.key,
    this.routeToSearchOnClickChip = false,
    this.onTap,
    this.onLongPress,
    this.onDoubleTap,
    this.onToggleSelected,
    this.onMoreActionsTap,
    this.imageMode = false,
    this.selectMode = false,
    this.selected = false,
  });

  @override
  State<StatefulWidget> createState() {
    return _ClipDataCardState();
  }
}

class _ClipDataCardState extends State<ClipDataCard>
    with TickerProviderStateMixin {
  static const _borderWidth = 2.0;
  static const _borderRadius = 12.0;

  final dbService = Get.find<DbService>();
  final appConfig = Get.find<ConfigService>();
  final androidChannelService = Get.find<AndroidChannelService>();
  final clipChannelService = Get.find<ClipChannelService>();
  var _slided = false;
  late final DoubleTapWrapper leftTapWrapper;
  late final DoubleTapWrapper rightTapWrapper;
  late final SlidableController slidController = SlidableController(this);
  bool showOriginData = false;

  /// 最近一次长按的时间戳：长按进入多选时手指必然存在微小位移，若不屏蔽，
  /// startActionPane 的 DismissiblePane 会把它误判为侧滑补选，导致
  /// onLongPress 与 onToggleSelected 在同一次手势内先后触发（表现为震动两下），
  /// 且 selectRange 会重算选中集合，可能把多选态意外清空，
  /// 进而让边缘返回手势失去拦截、直接退出应用。
  /// 采用时间窗而非布尔标记，避免标记未复位导致侧滑补选永久失效。
  DateTime? _lastLongPressAt;

  /// 最近一次长按震动的时间戳，用于对震动做去重，确保一次长按只震一次。
  DateTime? _lastHapticAt;

  /// 长按后屏蔽侧滑补选的时间窗。
  ///
  /// 取值需覆盖“长按判定完成 → 手指抬起”这一整段时间：
  /// Android 长按触发阈值约 500ms，用户长按后往往还会保持按住片刻再抬手，
  /// 600ms 的窗口在部分机型上偏紧，会出现长按与侧滑补选同时命中的“震动两下”。
  /// 放宽到 1000ms 后，仍远小于用户“先长按、再主动侧滑补选”的自然间隔，
  /// 不会影响正常的区间补选手势。
  static const _longPressGuardWindow = Duration(milliseconds: 1000);

  /// 当前是否处于“长按屏蔽侧滑补选”的时间窗内。
  bool get _isInLongPressGuard {
    final at = _lastLongPressAt;
    if (at == null) {
      return false;
    }
    return DateTime.now().difference(at) < _longPressGuardWindow;
  }

  @override
  void initState() {
    super.initState();
    slidController.animation.addListener(() {
      _slided = slidController.animation.value != 0;
    });
    leftTapWrapper = DoubleTapWrapper(
      doubleTapInterval: 200.ms,
      onTap: (details) {
        if (_slided) {
          slidController.close();
          return;
        }
        // 多选模式下不做双击判定：双击语义是"复制内容"，
        // 在多选场景既无意义，又会因 DoubleTapWrapper 的延迟导致
        // 点击后需等待 200ms 才响应（表现为"点了没反应、计数不更新"）。
        // 选中态完全交给外部受控（widget.selected），
        // 卡片自身不维护第二份 _selected，避免蓝框与真实选中集合分叉。
        widget.onTap?.call();
      },
      onDoubleTap: (details) {
        // 运行时判断而非 initState 时快照：卡片进入多选态后不应再响应双击复制。
        if (PlatformExt.isDesktop || widget.selectMode) {
          return;
        }
        widget.onDoubleTap?.call();
      },
    );
    rightTapWrapper = DoubleTapWrapper(
      doubleTapInterval: 200.ms,
      onTap: (details) {
        showMenu(details!.globalPosition - const Offset(0, 70));
      },
      onDoubleTap: (details) {
        widget.clip.data.copyContent(context: context, showFeedback: true);
      },
    );
  }

  @override
  void dispose() {
    super.dispose();
    slidController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = Card(
      elevation: 0,
      child: InkWell(
        // 同 ClipDataCardCompact：关闭 InkWell 自带反馈，震动由回调显式单次触发。
        enableFeedback: false,
        mouseCursor: SystemMouseCursors.basic,
        onTap: leftTapWrapper.wrapperTap,
        onTapDown: (_) {
          // 新手势开始：清空上一次长按留下的屏蔽时间窗，
          // 保证正常侧滑补选仍然可用。
          _lastLongPressAt = null;
        },
        onLongPress: () {
          // 长按归长按：记录时间戳，在时间窗内屏蔽侧滑补选。
          _lastLongPressAt = DateTime.now();
          // 震动在此显式触发（InkWell 的 enableFeedback 已关闭），并做时间窗去重，
          // 确保一次长按只产生一次震动，避免"快速震动两下"。
          final now = DateTime.now();
          if (_lastHapticAt == null ||
              now.difference(_lastHapticAt!) >
                  const Duration(milliseconds: 300)) {
            _lastHapticAt = now;
            HapticFeedback.mediumImpact();
          }
          widget.onLongPress?.call();
        },
        borderRadius: BorderRadius.circular(_borderRadius),
        child: Container(
          margin: widget.selectMode && widget.selected
              ? null
              : const EdgeInsets.all(_borderWidth),
          decoration: widget.selectMode && widget.selected
              ? BoxDecoration(
                  border: Border.all(
                    color: Colors.blue,
                    width: _borderWidth,
                  ),
                  borderRadius: BorderRadius.circular(_borderRadius),
                )
              : null,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipSimpleDataHeader(
                  clip: widget.clip,
                  routeToSearchOnClickChip: widget.routeToSearchOnClickChip,
                  showOriginData: showOriginData,
                  onShowOriginButtonClicked: () {
                    setState(() {
                      showOriginData = !showOriginData;
                    });
                  },
                ),
                widget.imageMode
                    ? IntrinsicHeight(
                        child: GestureDetector(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.file(
                              File(
                                widget.clip.data.content,
                              ),
                              fit: BoxFit.fitWidth,
                              width: 200,
                            ),
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => PreviewPage(
                                  clip: widget.clip,
                                ),
                              ),
                            );
                          },
                        ),
                      )
                    : Expanded(
                        child: Container(
                          alignment: Alignment.centerLeft,
                          child: ClipSimpleDataContent(
                            clip: widget.clip,
                            showOriginData: showOriginData,
                          ),
                        ),
                      ),
                ClipSimpleDataFooter(clip: widget.clip),
              ],
            ),
          ),
        ),
      ),
    );
    final Widget child;
    if(PlatformExt.isMobile || widget.selectMode){
      child = buildSlidable(content);
    } else {
      child = ClipNativeDragItemWrapper(
        clip: widget.clip,
        child: content,
      );
    }
    return GestureDetector(
      child: ClipRRect(child: child),
      onSecondaryTapDown: (details) {
        rightTapWrapper.call(details);
      },
    );
  }

  ///滑动操作块（移动端使用）
  Widget buildSlidable(Widget content){
    return Slidable(
      controller: slidController,
      key: ValueKey(widget.clip.data.id),
      startActionPane: ActionPane(
        motion: const SizedBox.shrink(),
        // 原值为 0.01，阈值近似为零，长按时的轻微手抖也会被判定为侧滑；
        // 这里放宽到 0.15，只有明确的横向滑动才会触发补选入口。
        extentRatio: 0.15,
        dismissible: DismissiblePane(
          onDismissed: () {},
          dismissThreshold: 0.15,
          confirmDismiss: () {
            slidController.close();
            // 本次手势属于长按（长按手势内附带的微小位移），不重复执行侧滑补选。
            if (_isInLongPressGuard) {
              return Future.value(false);
            }
            widget.onToggleSelected?.call();
            return Future.value(false);
          },
        ),
        children: const [],
      ),
      endActionPane: widget.selectMode
          ? null
          : ActionPane(
        extentRatio: 0.3,
        motion: const ScrollMotion(),
        children: [
          SlidableAction(
            onPressed: (context) {
              widget.onMoreActionsTap?.call();
            },
            autoClose: true,
            backgroundColor: Colors.blueGrey,
            foregroundColor: Colors.white,
            icon: Icons.menu,
            borderRadius: BorderRadius.circular(_borderRadius),
            label: TranslationKey.moreActions.tr,
          ),
        ],
      ),
      child: content,
    );
  }

  ///右键菜单
  void showMenu(Offset? position) {
    final menu = ContextMenu(
      entries: [
        MenuItem(
          label: widget.clip.data.top
              ? TranslationKey.cancelTopUp.tr
              : TranslationKey.topUp.tr,
          icon: widget.clip.data.top ? Icons.push_pin : Icons.push_pin_outlined,
          onSelected: () {
            var id = widget.clip.data.id;
            //置顶取反
            var isTop = !widget.clip.data.top;
            widget.clip.data.top = isTop;
            dbService.historyDao.setTop(id, isTop).then((v) {
              if (v == null || v <= 0) return;
              var opRecord = OperationRecord.fromSimple(
                Module.historyTop,
                OpMethod.update,
                id,
              );
              widget.onUpdate();
              setState(() {});
              dbService.opRecordDao.addAndNotify(opRecord);
            });
          },
        ),
        if (widget.clip.isText)
          MenuItem(
            label: TranslationKey.segmentWords.tr,
            icon: Icons.grain,
            onSelected: () {
              final home = Get.find<HomeController>();
              home.showSegmentWordsView(context, widget.clip.data.content);
            },
          ),
        if (widget.clip.data.canCopy)
          MenuItem(
            label: TranslationKey.copyContent.tr,
            icon: Icons.copy,
            onSelected: () {
              widget.clip.data
                  .copyContent(context: context, showFeedback: true);
            },
          ),
        if (!widget.clip.isFile)
          MenuItem(
            label: widget.clip.data.sync
                ? TranslationKey.resyncRecord.tr
                : TranslationKey.syncRecord.tr,
            icon: Icons.sync,
            onSelected: () {
              dbService.opRecordDao.resyncData(widget.clip.data.id);
            },
          ),
        if (widget.clip.isFile)
          MenuItem(
            label: TranslationKey.openFile.tr,
            icon: Icons.file_open,
            onSelected: () async {
              final file = File(widget.clip.data.content);
              await OpenFile.open(file.normalizePath);
            },
          ),
        if (widget.clip.isFile)
          MenuItem(
            label: TranslationKey.openFileFolder.tr,
            icon: Icons.folder,
            onSelected: () async {
              final file = File(widget.clip.data.content);
              file.openPath();
            },
          ),
        MenuItem(
          label: TranslationKey.tagsManagement.tr,
          icon: Icons.tag,
          onSelected: () {
            TagEditPage.goto(widget.clip.data.id);
          },
        ),
        if (!widget.clip.isFile && !widget.clip.isImage)
          MenuItem(
            label: TranslationKey.modifyContent.tr,
            icon: Icons.edit_note,
            onSelected: () {
              final homCtl = Get.find<HomeController>();
              homCtl.pushDrawer(
                widget: ClipboardDetailDrawer(
                  clipData: widget.clip,
                  modifyMode: true,
                ),
              );
            },
          ),
        MenuItem(
          label: TranslationKey.delete.tr,
          icon: Icons.delete,
          onSelected: () {
            widget.onRemoveClicked(widget.clip);
          },
        ),
      ],
      position: position,
      padding: const EdgeInsets.all(8.0),
      borderRadius: BorderRadius.circular(8),
    );
    menu.show(context);
  }

  ///删除数据
  Future<bool> removeData() async {
    var id = widget.clip.data.id;
    //删除tag
    await dbService.historyTagDao.removeAllByHisId(id);
    //删除历史
    return dbService.historyDao.delete(id).then((v) {
      if (v == null || v <= 0) return false;
      //移除未使用的剪贴板来源信息
      final sourceService = Get.find<ClipboardSourceService>();
      sourceService.removeNotUsed();
      //添加删除记录
      var opRecord = OperationRecord.fromSimple(
        Module.history,
        OpMethod.delete,
        id,
      );
      dbService.opRecordDao.addAndNotify(opRecord);
      return true;
    });
  }
}
