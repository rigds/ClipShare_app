part of '../clip_list_view.dart';

extension _ClipListFab on ClipListViewState {
  Widget _buildFloatingActionButton() {
    final actions = [
      ClipMultiSelectionFabAction(
        onPressed: _exitSelectionMode,
        tooltip:
            "${TranslationKey.deselect.tr} (${Constants.selectionExitShortcutLabel})",
        child: const Icon(MdiIcons.cancel),
      ),
      ClipMultiSelectionFabAction(
        onPressed: widget.list.isEmpty
            ? null
            : () {
                _selectionController.toggleSelectAll(widget.list);
                _refreshState();
              },
        tooltip: _selectionController.allSelected(widget.list)
            ? TranslationKey.cancelSelectAll.tr
            : TranslationKey.selectAll.tr,
        child: Icon(
          _selectionController.allSelected(widget.list)
              ? Icons.deselect
              : Icons.select_all,
        ),
      ),
      ClipMultiSelectionFabAction(
        onPressed: _showSelectedDeleteDialog,
        tooltip:
            "${TranslationKey.delete.tr} (${Constants.selectionDeleteShortcutLabel})",
        child: const Icon(Icons.delete_forever),
      ),
      ClipMultiSelectionFabAction(
        onPressed: _selectionController.canMergeCopy
            ? () async {
                await clipboardManager.copy(
                  ClipboardContentType.text,
                  _selectionController.mergedContent,
                );
                if (!mounted) {
                  return;
                }
                Global.showSnackBarSuc(
                  text: TranslationKey.copySuccess.tr,
                  context: context,
                );
                _cancelSelectionMode();
              }
            : null,
        tooltip: TranslationKey.copyMergedContent.tr,
        child: const Icon(Icons.content_copy_rounded),
      ),
      ClipMultiSelectionFabAction(
        onPressed: _selectionController.canMergeCopy
            ? () {
                final historyController = Get.find<HistoryController>();
                var loaded = false;
                historyController.export((_) {
                  if (loaded) {
                    return [];
                  }
                  loaded = true;
                  return _selectionController.selectedItems
                      .where((item) => !item.isFile)
                      .map((item) => item.data)
                      .toList();
                }).whenComplete(_cancelSelectionMode);
              }
            : null,
        tooltip: TranslationKey.output.tr,
        child: const Icon(MdiIcons.export),
      ),
    ];
    return ClipMultiSelectionFab(
      // 半径按动作数量统一计算，避免与历史弹窗参数不一致导致扇形疏密不同。
      distance: ClipMultiSelectionFab.suggestDistance(actions.length),
      selectMode: _selectionController.enabled,
      selectedCount: _selectionController.selectedCount,
      totalCount: widget.list.length,
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
