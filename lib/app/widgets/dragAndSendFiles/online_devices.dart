import 'package:clipshare/app/data/enums/translation_key.dart';
import 'package:clipshare/app/data/repository/entity/tables/device.dart';
import 'package:clipshare/app/widgets/device/device_card_simple.dart';
import 'package:clipshare/app/widgets/empty_content.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:get/get.dart';

class OnlineDevices extends StatelessWidget {
  final Axis direction;
  final List<Device> onlineList;
  final List<Device> selectedList;
  final void Function(Device device) onTap;

  /// 为 true 时高度随设备数量自适应（移动端发送文件面板用）。
  /// 需由外层 ConstrainedBox 限制最大高度，超出部分滚动。
  final bool adaptiveHeight;

  const OnlineDevices({
    super.key,
    this.direction = Axis.vertical,
    required this.onlineList,
    required this.onTap,
    required this.selectedList,
    this.adaptiveHeight = false,
  });

  Widget _buildHeader() {
    return Container(
      margin: const EdgeInsets.only(left: 10, bottom: 5),
      child: Row(
        children: [
          const Icon(
            Icons.devices_outlined,
          ),
          const SizedBox(width: 5),
          Text(
            TranslationKey.onlineDevices.tr,
            style: const TextStyle(fontSize: 17),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(Device dev) {
    return DeviceCardSimple(
      dev: dev,
      width: direction == Axis.horizontal ? 200 : null,
      showBorder: selectedList.contains(dev),
      onTap: () {
        onTap(dev);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (adaptiveHeight) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(),
          if (onlineList.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: EmptyContent(
                description: TranslationKey.noOnlineDevices.tr,
                size: 40,
              ),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  children: [for (final dev in onlineList) _buildCard(dev)],
                ),
              ),
            ),
        ],
      );
    }
    return Column(
      mainAxisAlignment: onlineList.isEmpty ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        _buildHeader(),
        Expanded(
          child: Visibility(
            visible: onlineList.isNotEmpty,
            replacement: Center(
              child: EmptyContent(
                description: TranslationKey.noOnlineDevices.tr,
              ),
            ),
            child: ListView.builder(
              scrollDirection: direction,
              itemCount: onlineList.length,
              physics: const AlwaysScrollableScrollPhysics(),
              itemBuilder: (ctx, idx) => _buildCard(onlineList[idx]),
            ),
          ),
        ),
      ],
    );
  }
}
