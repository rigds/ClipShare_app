part of '../clip_list_view.dart';

extension _ClipListItemRenderer on ClipListViewState {
  Widget renderItem(int i) {
    var item = widget.list[i];
    onRemoveClicked(ClipData item) {
      final onlyDeleteLocal = false.obs;
      Global.showTipsDialog(
        context: context,
        text: TranslationKey.clipListDeleteRecordDialogContent.tr,
        title: TranslationKey.deleteTips.tr,
        customWidget: Container(
          margin: 10.insetT,
          child: Obx(() {
            return CheckboxListTile(
                title: Text(TranslationKey.onlyLocal.tr),
                value: onlyDeleteLocal.value,
                onChanged: (selected) {
                  onlyDeleteLocal.value = selected ?? false;
                });
          }),
        ),
        showCancel: true,
        showNeutral: item.isFile || item.isImage,
        neutralText: TranslationKey.deleteWithFiles.tr,
        onOk: () => deleteItem(item, onlyDeleteLocal: onlyDeleteLocal.value),
        onNeutral: () => deleteItem(item, deleteFile: true, onlyDeleteLocal: onlyDeleteLocal.value),
      );
    }
    showClipBottomSheet(ClipData data){
      showModalBottomSheet(
        isScrollControlled: true,
        clipBehavior: Clip.antiAlias,
        context: context,
        elevation: 100,
        builder: (BuildContext context) {
          return SafeArea(
            child: ClipDetailDialog(
              dlgContext: context,
              clip: data,
              onUpdate: widget.onUpdate,
              onRemoveClicked: onRemoveClicked,
            ),
          );
        },
      );
    }

    return ClipDataCard(
      clip: widget.list[i],
      imageMode: widget.imageMasonryGridViewLayout,
      routeToSearchOnClickChip: widget.enableRouteSearch,
      selectMode: _selectionController.enabled,
      selected: _selectionController.contains(item),
      onTap: () {
        if (_selectionController.enabled) {
          _toggleSelectState(item);
        } else {
          var data = widget.list[i];
          if (isBigScreen) {
            homeCtrl.pushDrawer(
              widget: ClipboardDetailDrawer(clipData: data),
              beforeClosed: () {
                homeCtrl.resetDrawerWidth();
                return true;
              },
            );
          } else {
            showClipBottomSheet(data);
          }
        }
      },
      onToggleSelected: (){
        // 侧滑补选入口：恢复为原版 selectRange 行为，区间补选功能与初始版本一致。
        if (!_selectionController.enabled) {
          _enableSelectMode();
        }
        _selectionController.selectRange(List<ClipData>.from(widget.list), item);
        _refreshState();
      },
      onMoreActionsTap: (){
        showClipBottomSheet(widget.list[i]);
      },
      onLongPress: () {
        // 震动统一由 ClipDataCard 内部处理（InkWell.enableFeedback = false，
        // 回调内显式单次 mediumImpact 并做时间窗去重），此处只负责状态变更。
        // ⚠ 不要在此处再调用 HapticFeedback，否则会与组件内震动叠加成"快速震动两下"。
        _enableSelectMode();
        _selectionController.toggleItem(item);
        _refreshState();
      },
      onDoubleTap: () async {
        if (widget.list[i].isFile) {
          await OpenFile.open(widget.list[i].data.content);
          return;
        }
        History history = widget.list[i].data;
        history.copyContent(context: context, showFeedback: true);
      },
      onUpdate: widget.onUpdate,
      onRemoveClicked: onRemoveClicked,
    );
  }
}
