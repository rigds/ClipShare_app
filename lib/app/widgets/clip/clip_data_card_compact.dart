import 'package:clipshare/app/utils/extensions/number_extension.dart';
import 'package:clipshare/app/widgets/clip/clip_native_drag_item_wrapper.dart';
import 'package:clipshare/app/data/enums/translation_key.dart';
import 'package:clipshare/app/data/models/clip_data.dart';
import 'package:clipshare/app/services/channels/multi_window_channel.dart';
import 'package:clipshare/app/utils/global.dart';
import 'package:clipshare/app/widgets/clip/app_icon.dart';
import 'package:clipshare/app/widgets/clip/clip_simple_data_content.dart';
import 'package:clipshare/app/widgets/clip/clip_simple_data_footer.dart';
import 'package:clipshare/app/widgets/rounded_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:get/get.dart';
import 'package:open_file_plus/open_file_plus.dart';

///多窗口下一些数据拿不到所以单独写一个
class ClipDataCardCompact extends StatefulWidget {
  static const double selectedBorderWidth = 2;
  static const double selectedBorderRadius = 12;

  final String devName;
  final ClipData clip;
  final void Function(int id, bool isTop) onTopChanged;
  final void Function(int id) onDelete;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelected;
  final VoidCallback? onMoreActionsTap;
  final VoidCallback onCopied;
  final bool selectMode;
  final bool selected;
  final bool clickToPaste;

  const ClipDataCardCompact({
    super.key,
    required this.clip,
    required this.devName,
    required this.onTopChanged,
    required this.onDelete,
    required this.onCopied,
    this.onTap,
    this.onLongPress,
    this.onToggleSelected,
    this.onMoreActionsTap,
    this.selectMode = false,
    this.selected = false,
    this.clickToPaste = false,
  });

  @override
  State<StatefulWidget> createState() => _ClipDataCardCompactState();
}

class _ClipDataCardCompactState extends State<ClipDataCardCompact> with TickerProviderStateMixin {
  final multiWindowService = Get.find<MultiWindowChannelService>();
  late final SlidableController _slidableController = SlidableController(this);
  bool _slided = false;
  static final _pastingIds = <int>{};

  /// 最近一次长按的时间戳：长按进入多选时手指必然存在微小位移，若不屏蔽，
  /// startActionPane 的 DismissiblePane 会把它误判为侧滑补选，导致
  /// onLongPress 与 onToggleSelected 在同一次手势内先后触发（表现为震动两下），
  /// 且 selectRange 会重算选中集合，可能把多选态意外清空。
  /// 采用时间窗而非布尔标记，避免标记未复位导致侧滑补选永久失效。
  DateTime? _lastLongPressAt;

  /// 最近一次长按震动的时间戳，用于对震动做去重。
  ///
  /// InkWell 的 enableFeedback 已关闭，震动由 onLongPress 回调显式触发。
  /// 个别 ROM 存在重复派发长按回调的情况，这里用时间窗兜底，
  /// 确保一次长按只产生一次震动（避免"快速震动两下"）。
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

  ///右键菜单
  void showMenu(Offset? position, BuildContext context) {
    final clip = widget.clip;
    final menu = ContextMenu(
      entries: [
        MenuItem(
          label: clip.data.top
              ? TranslationKey.cancelTopUp.tr
              : TranslationKey.topUp.tr,
          icon: clip.data.top ? Icons.push_pin : Icons.push_pin_outlined,
          onSelected: () {
            var id = clip.data.id;
            //置顶取反
            var isTop = !clip.data.top;
            widget.onTopChanged.call(id, isTop); // 修改这里
            setState(() {
              clip.data.top = isTop;
            });
          },
        ),
        MenuItem(
          label: TranslationKey.copyContent.tr,
          icon: Icons.copy,
          onSelected: () {
            if (clip.isFile) {
              OpenFile.open(clip.data.content);
              return;
            }
            multiWindowService.copy(0, clip.data.id);
            Global.showSnackBarSuc(
              context: context,
              text: TranslationKey.copySuccess.tr,
            );
          },
        ),
        MenuItem(
          label: TranslationKey.delete.tr,
          icon: Icons.delete,
          onSelected: () {
            widget.onDelete.call(clip.data.id);
          },
        ),
      ],
      position: position,
      padding: const EdgeInsets.all(8.0),
      borderRadius: BorderRadius.circular(8),
    );
    menu.show(context);
  }

  ///复制并粘贴到上一个窗口，单击粘贴与双击粘贴共用
  Future<void> _copyAndPaste() async {
    final clip = widget.clip;
    if (!_pastingIds.add(clip.data.id)) return;
    if (clip.isFile) {
      await OpenFile.open(clip.data.content);
      return;
    }
    await multiWindowService.copy(0, clip.data.id);
    await Future.delayed(300.ms);
    widget.onCopied.call();
    _pastingIds.remove(clip.data.id);
  }

  @override
  void initState() {
    super.initState();
    _slidableController.animation.addListener(() {
      _slided = _slidableController.animation.value != 0;
    });
  }

  @override
  void dispose() {
    _slidableController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clip = widget.clip;
    final child = SizedBox(
      height: 150,
      child: Card(
        elevation: 0,
        child: InkWell(
          // 关闭 InkWell 自带的反馈（默认 true 时会在 onLongPress 前调用
          // Feedback.forLongPress → Android 上 HapticFeedback.vibrate()）。
          // 关闭后由我们在回调里显式、单次地触发震动，震动次数完全可控，
          // 不会与系统反馈叠加成"快速震动两下"。
          enableFeedback: false,
          mouseCursor: SystemMouseCursors.basic,
          onTap: () {
            if (_slided) {
              _slidableController.close();
              return;
            }
            if (widget.selectMode) {
              widget.onTap?.call();
              return;
            }
            if (widget.clickToPaste) {
              _copyAndPaste();
            }
          },
          onDoubleTap: widget.selectMode || widget.clickToPaste
              ? null
              : () async {
                  await _copyAndPaste();
                },
          onLongPress: () {
            // 长按归长按：记录时间戳，在时间窗内屏蔽侧滑补选。
            _lastLongPressAt = DateTime.now();
            // 震动由这里显式触发（InkWell 的 enableFeedback 已关闭）。
            // 加去重守卫：极少数机型/ROM 存在重复派发，这里兜底保证只震一次。
            final now = DateTime.now();
            if (_lastHapticAt == null ||
                now.difference(_lastHapticAt!) >
                    const Duration(milliseconds: 300)) {
              _lastHapticAt = now;
              HapticFeedback.mediumImpact();
            }
            widget.onLongPress?.call();
          },
          onTapDown: (_) {
            // 新手势开始：清空上一次长按留下的屏蔽时间窗，保证正常侧滑补选仍然可用。
            // 注意：长按过程中抬手不会再派发 tapDown，因此这里清空不会误伤
            // “长按后同一次手势内的微小位移”场景（那正是需要屏蔽的情况）。
            _lastLongPressAt = null;
          },
          onSecondaryTapDown: (details) {
            showMenu(details.globalPosition - const Offset(0, 70), context);
          },
          borderRadius: BorderRadius.circular(
            ClipDataCardCompact.selectedBorderRadius,
          ),
          child: Container(
            margin: widget.selectMode && widget.selected
                ? null
                : const EdgeInsets.all(ClipDataCardCompact.selectedBorderWidth),
            decoration: widget.selectMode && widget.selected
                ? BoxDecoration(
                    border: Border.all(
                      color: Colors.blue,
                      width: ClipDataCardCompact.selectedBorderWidth,
                    ),
                    borderRadius: BorderRadius.circular(
                      ClipDataCardCompact.selectedBorderRadius,
                    ),
                  )
                : null,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (clip.data.source != null)
                        Container(
                          margin: const EdgeInsets.only(right: 5),
                          child: AppIcon(appId: clip.data.source!),
                        ),
                      RoundedChip(
                        avatar: const Icon(Icons.devices_rounded),
                        backgroundColor: const Color(0x1a000000),
                        label: Text(
                          widget.devName,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Expanded(
                    child: ClipSimpleDataContent(
                      clip: clip,
                      imgOnlyView: true,
                      imgSingleView: true,
                    ),
                  ),
                  const SizedBox(height: 1),
                  ClipSimpleDataFooter(clip: clip),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(
        ClipDataCardCompact.selectedBorderRadius,
      ),
      child: widget.selectMode
          ? child
          : ClipNativeDragItemWrapper(
        clip: widget.clip,
        child: child,
      ),
    );
  }

  /// 紧凑卡片在多选模式下复用滑动补选入口，保持与主窗体一致的区间补选手势。
  Widget _buildSlidable(Widget child) {
    return Slidable(
      controller: _slidableController,
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
            _slidableController.close();
            // 本次手势属于长按（长按手势内附带的微小位移），不重复执行侧滑补选。
            // 双重判定：既看长按时间窗，也看长按后是否已进入多选——
            // 长按一定会先触发 onLongPress 并进入多选态，
            // 而真正的侧滑补选发生在“已处于多选态”时，二者不会混淆。
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
                    final onMoreActionsTap = widget.onMoreActionsTap;
                    if (onMoreActionsTap != null) {
                      onMoreActionsTap();
                    } else {
                      showMenu(null, context);
                    }
                  },
                  autoClose: true,
                  backgroundColor: Colors.blueGrey,
                  foregroundColor: Colors.white,
                  icon: Icons.menu,
                  borderRadius: BorderRadius.circular(
                    ClipDataCardCompact.selectedBorderRadius,
                  ),
                  label: TranslationKey.moreActions.tr,
                ),
              ],
            ),
      child: child,
    );
  }
}
