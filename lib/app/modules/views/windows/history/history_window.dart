import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clipshare/app/data/enums/channelMethods/multi_window_method.dart';
import 'package:clipshare/app/data/enums/multi_window_tag.dart';
import 'package:clipshare/app/data/enums/translation_key.dart';
import 'package:clipshare/app/data/enums/window_type.dart';
import 'package:clipshare/app/data/models/clip_data.dart';
import 'package:clipshare/app/data/models/keyboard_shortcut.dart';
import 'package:clipshare/app/data/models/search_filter.dart';
import 'package:clipshare/app/data/repository/entity/tables/app_info.dart';
import 'package:clipshare/app/data/repository/entity/tables/device.dart';
import 'package:clipshare/app/data/repository/entity/tables/history.dart';
import 'package:clipshare/app/listeners/window_control_clicked_listener.dart';
import 'package:clipshare/app/services/channels/multi_window_channel.dart';
import 'package:clipshare/app/services/multi_window_config_service.dart';
import 'package:clipshare/app/services/multi_window_dispatch_service.dart';
import 'package:clipshare/app/services/window_control_service.dart';
import 'package:clipshare/app/utils/constants.dart';
import 'package:clipshare/app/utils/extensions/number_extension.dart';
import 'package:clipshare/app/utils/global.dart';
import 'package:clipshare/app/widgets/base/custom_keyboard_listener.dart';
import 'package:clipshare/app/widgets/clip/clip_data_card_compact.dart';
import 'package:clipshare/app/widgets/clip/clip_multi_selection_controller.dart';
import 'package:clipshare/app/widgets/clip/clip_multi_selection_fab.dart';
import 'package:clipshare/app/widgets/condition_widget.dart';
import 'package:clipshare/app/widgets/empty_content.dart';
import 'package:clipshare/app/widgets/filter/history_filter.dart';
import 'package:clipshare/app/widgets/loading.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_expandable_fab/flutter_expandable_fab.dart';
import 'package:flutter_material_design_icons/flutter_material_design_icons.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

class HistoryWindow extends StatefulWidget {
  final WindowController windowController;

  const HistoryWindow({
    super.key,
    required this.windowController,
  });

  @override
  State<StatefulWidget> createState() {
    return _HistoryWindowState();
  }
}

class CompactClipData {
  final String devName;
  final ClipData data;

  const CompactClipData({required this.devName, required this.data});
}

class _HistoryWindowState extends State<HistoryWindow> with WindowListener, WindowControlClickedListener implements MultiWindowMessageListener {
  final ScrollController _scrollController = ScrollController();
  final _selectionController = ClipMultiSelectionController();
  List<CompactClipData> _list = [];
  bool _loadNewData = false;
  bool _loading = true;
  bool _showBackToTopButton = false;
  final multiWindowService = Get.find<MultiWindowChannelService>();
  final multiWindowConfigService = Get.find<MultiWindowConfigService>();
  final windowControlService = Get.find<WindowControlService>();
  Timer? _timer;
  bool filterLoading = true;
  /// 弹窗最近一次从隐藏状态恢复显示的时间，用于抑制显示瞬间的失焦兜底关闭。
  DateTime? _lastShownAt;
  /// 置顶状态订阅：置顶按钮切换后同步主窗口（点击外部是否关闭由主窗口判断）
  StreamSubscription<bool>? _pinnedSubscription;
  late final HistoryFilterController historyFilterController;

  @override
  void initState() {
    super.initState();
    _pinnedSubscription = windowControlService.historyPopupPinned.listen((pinned) {
      multiWindowService.setHistoryPinned(pinned);
    });
    windowManager.addListener(this);
    multiWindowMsgDispatchService.addListener(this);
    // 监听滚动事件
    _scrollController.addListener(_scrollListener);
    windowControlService.addListener(this);
    historyFilterController = HistoryFilterController(
      allDevices: [],
      allTagNames: [],
      allSources: [],
      isBigScreen: false,
      loadSearchCondition: loadSearchCondition,
      onChanged: (filter) {
        refresh();
      },
      onSearchBtnClicked: refresh,
      filter: SearchFilter(),
    );
    loadSearchCondition();
    refresh();
  }

  void _enableSelectMode() {
    if (_selectionController.enabled) {
      return;
    }
    _selectionController.enable();
    setState(() {});
  }

  void _refreshState() {
    setState(() {});
  }

  /// 统一清理历史弹窗多选状态，避免快捷键和 FAB 出现不一致的退出行为。
  void _exitSelectionMode() {
    if (!_selectionController.enabled) {
      return;
    }
    _selectionController.clearAndExit();
    _refreshState();
  }

  @override
  FutureOr<void> onMultiWindowMessage(MultiWindowMethod method, Map<String, dynamic> args, int fromWindowId) {
    switch (method) {
      //更新通知
      case MultiWindowMethod.notify:
        refresh();
        break;
      case MultiWindowMethod.updateConfig:
        setState(() {});
        break;
      //从隐藏状态恢复显示弹窗
      case MultiWindowMethod.showWindowFromHide:
        var position = args["position"];
        if (position != null) {
          var [x, y] = (position as List<dynamic>).cast<double>();
          windowManager.setPosition(Offset(x, y));
        }
        windowControlService.setHistoryPopupPinned(false);
        // 记录显示时间：弹窗不激活，正常情况下不会产生失焦事件；
        // 该时间用于抑制显示瞬间意外失焦导致的兜底关闭，避免窗口“闪一下就消失”。
        _lastShownAt = DateTime.now();
        widget.windowController.show();
        windowManager.setAlwaysOnTop(true);
        // 不再调用 windowManager.focus()：弹窗已通过 WS_EX_NOACTIVATE 设为不激活，
        // 避免抢占前台焦点打断用户输入
        // 重新定位
        if (args["isRelocate"] != true) {
          historyFilterController.resetFilter();
          refresh();
        }
        break;
      //关闭（隐藏）窗口
      case MultiWindowMethod.closeWindow:
        widget.windowController.hide();
        break;
      //更新基础信息，如设备信息，来源信息，标签信息
      case MultiWindowMethod.updateAllBaseData:
        loadSearchCondition();
        break;
      default:
    }
  }

  @override
  void onWindowMove() {
    _timer?.cancel();
    _timer = Timer(500.ms, () {
      _timer = null;
      windowManager.getPosition().then((pos) {
        multiWindowService.storeWindowPos(0, "history", pos);
      });
    });
  }

  @override
  Future<void> onWindowResized() async {
    super.onWindowResized();
    final size = await windowManager.getSize();
    await multiWindowService.updateWindowSize(0, WindowType.history, size);
  }

  @override
  /// 弹窗失焦兜底：弹窗不激活后几乎不会触发失焦事件，这里仅在弹窗
  /// 意外获得焦点并再次失去时兜底关闭，避免弹窗残留。
  void onWindowBlur() {
    // 抑制显示瞬间的意外失焦，避免窗口“闪一下就消失”。
    final shownAt = _lastShownAt;
    if (shownAt != null && DateTime.now().difference(shownAt) < 500.ms) {
      return;
    }
    _closeIfPreferenceEnabled();
  }

  /// 按主窗口偏好决定是否关闭弹窗，双击复制与失焦兜底共用。
  void _closeIfPreferenceEnabled() {
    //置顶状态下粘贴后不自动关闭，除非用户手动关闭
    if (windowControlService.historyPopupPinned.value) {
      return;
    }
    if (!multiWindowConfigService.autoClosePopupOnBlur) {
      return;
    }
    // 统一走主窗口维护的隐藏流程，避免子窗口自行关闭后主窗口状态不同步。
    multiWindowService.closeWindow(0, widget.windowController.windowId, MultiWindowTag.history);
  }

  @override
  void onCloseBtnClicked(bool isHide) {
    multiWindowService.closeWindow(0, widget.windowController.windowId, MultiWindowTag.history);
  }

  void _scrollListener() {
    if (_scrollController.offset == 0) {
      Future.delayed(100.ms, () {
        _list = _list.sublist(0, min(_list.length, 20));
        _selectionController.removeMissingItems(_list.map((item) => item.data));
        setState(() {});
      });
    }
    // 判断是否快要滑动到底部
    if (_scrollController.position.extentAfter <= 200 && !_loadNewData) {
      refresh(loadMore: true);
    }
    if (_scrollController.offset >= 300) {
      if (!_showBackToTopButton) {
        setState(() {
          _showBackToTopButton = true;
        });
      }
    } else {
      if (_showBackToTopButton) {
        setState(() {
          _showBackToTopButton = false;
        });
      }
    }
  }

  Future<void> refresh({
    bool loadMore = false,
    bool showLoading = false,
  }) async {
    if (loadMore) {
      setState(() {
        _loadNewData = true;
      });
    } else {
      if (showLoading) {
        setState(() {
          _loading = true;
        });
      }
    }
    return Future.delayed(500.ms, () {
      var fromId = 0;
      if (loadMore) {
        fromId = _list.isEmpty ? 0 : _list.last.data.data.id;
      }
      return multiWindowService
          .getHistories(0, fromId, historyFilterController.filter)
          .then(
            (json) {
              var data = jsonDecode(json);
              var devInfos = data["devInfos"] as Map<String, dynamic>;
              var lst = History.fromJsonList(data["list"]);
              var res = List<CompactClipData>.empty(growable: true);
              for (var history in lst) {
                res.add(
                  CompactClipData(
                    devName: devInfos[history.devId] ?? TranslationKey.unknown.tr,
                    data: ClipData(history),
                  ),
                );
              }
              setState(() {
                if (loadMore) {
                  _list.addAll(res);
                } else {
                  _list = res;
                }
                _selectionController.removeMissingItems(
                  _list.map((item) => item.data),
                );
                _loadNewData = false;
              });
            },
          )
          .whenComplete(
            () => setState(() {
              _loading = false;
            }),
          );
    });
  }

  @override
  void dispose() {
    super.dispose();
    _pinnedSubscription?.cancel();
    windowManager.removeListener(this);
    windowControlService.removeListener(this);
    _scrollController.removeListener(_scrollListener);
    multiWindowMsgDispatchService.removeListener(this);
  }

  Future<void> loadSearchCondition() async {
    final devices = <Device>[];
    final tags = <String>[];
    final sources = <AppInfo>[];
    await multiWindowService.getAllDevices(0).then(
      ((json) {
        final data = (jsonDecode(json) as List<dynamic>).cast<Map<String, dynamic>>();
        devices.addAll(data.map(Device.fromJson));
      }),
    );
    await multiWindowService.getAllTagNames(0).then((json) {
      var lst = (jsonDecode(json) as List<dynamic>).cast<String>();
      tags.addAll(lst);
    });
    await multiWindowService.getAllSources(0).then((list) {
      sources.addAll(list);
    });
    historyFilterController.setAllDevices(devices);
    historyFilterController.setAllTagNames(tags);
    historyFilterController.setAllSources(sources);
    if (filterLoading) {
      setState(() {
        filterLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomKeyboardListener(
        shortcuts: [
          KeyboardShortcut(
            physicalKeys: {PhysicalKeyboardKey.escape},
            onTrigger: _exitSelectionMode,
          ),
        ],
        child: Column(
          children: [
            if (Platform.isMacOS) const SizedBox(height: 15),
            if (!filterLoading)
              Container(
                margin: const EdgeInsets.only(top: 10),
                child: HistoryFilter(
                  controller: historyFilterController,
                  showFillColor: true,
                  onFilterTypeChanged: (_) {
                    setState(() {
                      _loading = true;
                    });
                  },
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => Future.wait<void>([loadSearchCondition(), refresh()]),
                child: ConditionWidget(
                  visible: _loading,
                  replacement: ConditionWidget(
                    visible: _list.isEmpty,
                    replacement: ListView.builder(
                      itemCount: _list.length,
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemBuilder: (ctx, idx) {
                        final item = _list[idx];
                        return ClipDataCardCompact(
                          devName: item.devName,
                          clip: item.data,
                          clickToPaste: multiWindowConfigService.clickToPaste,
                          selectMode: _selectionController.enabled,
                          selected: _selectionController.contains(item.data),
                          onCopied: _closeIfPreferenceEnabled,
                          onTap: () {
                            // 多选态下的点击：只切换当前项，语义单一、与计数严格一致。
                            // 这里不再调用震动，避免与 onLongPress 的震动叠加成“两下”。
                            if (_selectionController.enabled) {
                              _selectionController.toggleItem(item.data);
                              _refreshState();
                            }
                          },
                          onLongPress: () {
                            // 长按是进入多选 / 选中当前项的唯一入口。
                            //
                            // 震动统一由 ClipDataCardCompact 内部处理：
                            // 其 InkWell 已设置 enableFeedback = false，避免系统长按反馈
                            // (Feedback.forLongPress → HapticFeedback.vibrate) 与手动震动
                            // 叠加成"快速震动两下"；组件内对震动做了时间窗去重，
                            // 保证一次长按只震一次（mediumImpact）。
                            //
                            // 此处只负责状态变更，不要再调用 HapticFeedback。
                            _enableSelectMode();
                            _selectionController.toggleItem(item.data);
                            _refreshState();
                          },
                          onToggleSelected: () {
                            // 侧滑手势触发：语义上属于“补选一段区间”。
                            //
                            // 但实测发现 onLongPress 抬手时的微小位移也会进入这里，
                            // 由于 selectRange 在“已有选中项”时会自动填充整段区间
                            // （见 ClipMultiSelectionController.selectRange），
                            // 表现为“点一下突然选中一大堆、计数与蓝框还对不上”。
                            //
                            // 因此这里改为严格的单项切换：点按/补选都只影响当前一项，
                            // 选中结果与计数、蓝框始终一一对应，彻底消除区间误选。
                            if (!_selectionController.enabled) {
                              return;
                            }
                            _selectionController.toggleItem(item.data);
                            _refreshState();
                          },
                          onTopChanged: (int id, bool isTop) {
                            multiWindowService.updateHistoryTop(0, id, isTop);
                          },
                          onDelete: (int id) {
                            multiWindowService.deleteHistory(0, id);
                            setState(() {
                              _list.removeWhere(
                                (entry) => entry.data.data.id == id,
                              );
                              _selectionController.removeMissingItems(
                                _list.map((entry) => entry.data),
                              );
                            });
                          },
                        );
                      },
                    ),
                    child: EmptyContent(),
                  ),
                  child: const Loading(),
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: ExpandableFab.location,
      floatingActionButton: _buildSelectionFab(),
    );
  }

  Widget _buildSelectionFab() {
    // 注意：canMergeCopy 原本是 build() 内的局部变量，这里必须自行计算。
    final canMergeCopy = _selectionController.canMergeCopy;
    final actions = [
      ClipMultiSelectionFabAction(
        onPressed: _exitSelectionMode,
        tooltip:
            "${TranslationKey.deselect.tr} (${Constants.selectionExitShortcutLabel})",
        child: const Icon(MdiIcons.cancel),
      ),
      ClipMultiSelectionFabAction(
        onPressed: _list.isEmpty
            ? null
            : () {
                final items =
                    _list.map((entry) => entry.data).toList(growable: false);
                _selectionController.toggleSelectAll(items);
                _refreshState();
              },
        tooltip: _selectionController.allSelected(_list.map((entry) => entry.data))
            ? TranslationKey.cancelSelectAll.tr
            : TranslationKey.selectAll.tr,
        child: Icon(
          _selectionController.allSelected(_list.map((entry) => entry.data))
              ? Icons.deselect
              : Icons.select_all,
        ),
      ),
      ClipMultiSelectionFabAction(
        onPressed: canMergeCopy
            ? () async {
                await multiWindowService.copyContent(
                  0,
                  _selectionController.mergedContent,
                );
                if (!mounted) {
                  return;
                }
                Global.showSnackBarSuc(
                  context: context,
                  text: TranslationKey.copySuccess.tr,
                );
                _exitSelectionMode();
              }
            : null,
        tooltip: TranslationKey.copyMergedContent.tr,
        child: const Icon(Icons.content_copy_rounded),
      ),
    ];
    return ClipMultiSelectionFab(
      // 与主列表共用同一套半径计算规则，保证不同窗口展开疏密一致。
      distance: ClipMultiSelectionFab.suggestDistance(actions.length),
      selectMode: _selectionController.enabled,
      selectedCount: _selectionController.selectedCount,
      totalCount: _list.length,
      showBackToTopButton: _showBackToTopButton,
      onBackToTop: () {
        Future.delayed(100.ms, () {
          _scrollController.animateTo(
            0,
            duration: 500.ms,
            curve: Curves.easeInOut,
          );
        });
      },
      actions: actions,
    );
  }
}
