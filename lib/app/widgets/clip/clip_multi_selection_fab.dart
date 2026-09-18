import 'dart:math' as math;

import 'package:clipshare/app/data/enums/translation_key.dart';
import 'package:clipshare/app/utils/extensions/number_extension.dart';
import 'package:flutter/material.dart';
import 'package:flutter_expandable_fab/flutter_expandable_fab.dart';

/// 多选浮动按钮动作定义。
///
/// 使用可空回调表示动作禁用态，保持主窗体与历史弹窗的可用性提示一致。
class ClipMultiSelectionFabAction {
  final VoidCallback? onPressed;
  final String tooltip;
  final Widget child;

  const ClipMultiSelectionFabAction({
    required this.onPressed,
    required this.tooltip,
    required this.child,
  });
}

/// 多选模式通用 FAB。
///
/// 统一渲染计数徽标、回到顶部按钮以及扇形动作区，
/// 让不同列表只关心自身动作与滚动回调。
///
/// 折叠态布局统一规则（主列表与历史弹窗共用，避免各窗口参数不同导致“折叠不统一”）：
/// - 主 FAB（menu/close）：右下角，距边 [margin]，直径 [fabSize]。
/// - 回到顶部按钮：折叠态与主 FAB 同格；展开态抬到主 FAB 上方一格。
/// - 计数徽标：固定在“回到顶部按钮”左侧，底部与主 FAB 对齐。
///
/// 展开为向左上 90° 扇形，半径由 [distance] 决定；调用方按动作数量传入，
/// 保证按钮间距一致、不再拥挤。
class ClipMultiSelectionFab extends StatelessWidget {
  /// 主 FAB 直径（ExpandableFabSize.regular）。
  static const double fabSize = 56;

  /// 屏幕边缘安全间距。
  static const double margin = 16;

  /// 计数徽标与右侧按钮之间的水平间隙。
  static const double _badgeGap = 12;

  /// 展开态扇形半径推荐值（按动作数量计算，避免按钮堆叠、视觉拥挤）。
  ///
  /// 动作按钮直径 [fabSize]，扇形 90° 均分时相邻圆心距需不小于按钮直径 + 间隙，
  /// 故半径 R 需满足 `2 * R * sin(步长 / 2) >= 间距`，再叠加主 FAB 半径余量。
  static double suggestDistance(int actionCount) {
    const spacing = fabSize + 12;
    if (actionCount <= 1) {
      return 96;
    }
    final step = (90 / (actionCount - 1)) * math.pi / 180;
    final half = step / 2;
    final required = half <= 0 ? spacing.toDouble() : spacing / (2 * math.sin(half));
    // 限制在合理区间，防止动作极多时按钮飞出屏幕。
    return (required + fabSize / 2).clamp(96.0, 168.0);
  }

  final bool selectMode;
  final int selectedCount;
  final int totalCount;
  final bool showBackToTopButton;
  final double distance;
  final VoidCallback onBackToTop;
  final List<ClipMultiSelectionFabAction> actions;

  const ClipMultiSelectionFab({
    super.key,
    required this.selectMode,
    required this.distance,
    required this.selectedCount,
    required this.totalCount,
    required this.showBackToTopButton,
    required this.onBackToTop,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 折叠态与展开态的纵坐标：展开时“回到顶部”上移一格给扇形让位。
    final collapsedBottom = margin;
    final expandedBottom = margin + fabSize + 8;
    return SizedBox.expand(
      child: Stack(
        children: [
          // 计数徽标：固定在“回到顶部按钮”左侧，底部与主 FAB 对齐，避免与扇形按钮重叠。
          Positioned(
            right: margin + fabSize + _badgeGap,
            bottom: collapsedBottom,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: selectMode ? 1 : 0,
                duration: 200.ms,
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Text(
                        '$selectedCount / $totalCount',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 回到顶部按钮：折叠态与主 FAB 同位，展开态上移；隐藏时不接收手势。
          Positioned(
            right: margin,
            bottom: selectMode ? expandedBottom : collapsedBottom,
            child: IgnorePointer(
              ignoring: !showBackToTopButton,
              child: AnimatedOpacity(
                opacity: showBackToTopButton ? 1 : 0,
                duration: 200.ms,
                child: FloatingActionButton.small(
                  heroTag: 'clipBackToTopFab',
                  onPressed: onBackToTop,
                  tooltip: TranslationKey.backToTop.tr,
                  child: const Icon(Icons.arrow_upward),
                ),
              ),
            ),
          ),
          // 多选动作区：仅在多选模式下挂载，避免隐藏状态仍吞掉整屏手势。
          if (selectMode)
            _MultiSelectionFabHost(
              distance: distance,
              actions: actions,
            ),
        ],
      ),
    );
  }
}

/// 多选动作区宿主。
///
/// 关键设计：把 `ExpandableFab` 缓存在 State 中，并在 build 里复用**同一个实例**。
/// `flutter_expandable_fab` 的实现中 `didUpdateWidget` 会无条件调用 `close()`：
///
/// ```dart
/// @override
/// void didUpdateWidget(covariant ExpandableFab oldWidget) {
///   ...
///   // Always reset FAB to closed state when widget is rebuilt
///   close();
/// }
/// ```
///
/// 而列表在滚动、刷新、选中项变化时都会 `setState` 重建 FAB，于是扇形刚展开就被强制收起，
/// 表现为“点开后偶尔自动关闭”。复用同一个 widget 实例后，Flutter 的 `updateChild`
/// 会走 `newWidget == oldWidget` 的快路径直接跳过更新，`didUpdateWidget` 不再被触发。
/// 依赖项（半径 / 动作列表）变化时再显式重建缓存。
class _MultiSelectionFabHost extends StatefulWidget {
  final double distance;
  final List<ClipMultiSelectionFabAction> actions;

  const _MultiSelectionFabHost({
    required this.distance,
    required this.actions,
  });

  @override
  State<_MultiSelectionFabHost> createState() => _MultiSelectionFabHostState();
}

class _MultiSelectionFabHostState extends State<_MultiSelectionFabHost> {
  late ExpandableFab _fab;

  @override
  void initState() {
    super.initState();
    _fab = _buildFab();
  }

  ExpandableFab _buildFab() {
    return ExpandableFab(
      distance: widget.distance,
      type: ExpandableFabType.fan,
      fanAngle: 90,
      overlayStyle: const ExpandableFabOverlayStyle(blur: 8),
      openButtonBuilder: RotateFloatingActionButtonBuilder(
        fabSize: ExpandableFabSize.regular,
        heroTag: 'clipSelectionFab',
        child: const Icon(Icons.menu),
      ),
      closeButtonBuilder: DefaultFloatingActionButtonBuilder(
        fabSize: ExpandableFabSize.regular,
        heroTag: 'clipSelectionFab',
        child: const Icon(Icons.close),
      ),
      children: widget.actions
          .map(_buildActionButton)
          .toList(growable: false),
    );
  }

  @override
  void didUpdateWidget(covariant _MultiSelectionFabHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只有会改变扇形几何 / 内容 / 可用性的输入变化时才重建，避免重置展开状态。
    if (widget.distance != oldWidget.distance ||
        !_sameActions(widget.actions, oldWidget.actions)) {
      _fab = _buildFab();
    }
  }

  /// 动作列表等价判断：仅在数量、禁用态或图标发生变化时才认为需要重建。
  bool _sameActions(
    List<ClipMultiSelectionFabAction> a,
    List<ClipMultiSelectionFabAction> b,
  ) {
    if (identical(a, b)) {
      return true;
    }
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if ((a[i].onPressed == null) != (b[i].onPressed == null)) {
        return false;
      }
      if (a[i].child.runtimeType != b[i].child.runtimeType) {
        return false;
      }
      if (a[i].child is Icon && b[i].child is Icon) {
        final iconA = a[i].child as Icon;
        final iconB = b[i].child as Icon;
        if (iconA.icon != iconB.icon) {
          return false;
        }
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return _fab;
  }

  /// 禁用态统一使用灰色背景，避免不同页面的多选操作视觉反馈不一致。
  FloatingActionButton _buildActionButton(ClipMultiSelectionFabAction action) {
    final bgColor = action.onPressed == null ? Colors.grey[400] : null;
    return FloatingActionButton(
      heroTag: null,
      onPressed: action.onPressed,
      tooltip: action.tooltip,
      backgroundColor: bgColor,
      child: action.child,
    );
  }
}
