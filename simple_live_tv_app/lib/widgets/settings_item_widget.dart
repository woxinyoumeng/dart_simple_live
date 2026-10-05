import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/widgets/highlight_widget.dart';

class SettingsItemWidget extends StatelessWidget {
  final AppFocusNode foucsNode;
  final Map<dynamic, String> items;
  final dynamic value;
  final String title;
  final bool autofocus;
  final Function(dynamic) onChanged;
  const SettingsItemWidget({
    required this.foucsNode,
    required this.items,
    required this.value,
    required this.title,
    required this.onChanged,
    this.autofocus = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return HighlightWidget(
      focusNode: foucsNode,
      autofocus: autofocus,
      borderRadius: AppStyle.radius16,
      onLeftKey: () {
        if (items.isEmpty) return KeyEventResult.handled;
        onChanged(
          pickAdjacentItem(items: items, value: value, forward: false),
        );
        return KeyEventResult.handled;
      },
      onRightKey: () {
        if (items.isEmpty) return KeyEventResult.handled;
        onChanged(
          pickAdjacentItem(items: items, value: value, forward: true),
        );
        return KeyEventResult.handled;
      },
      onTap: () {
        showSettingsDialog();
      },
      child: Obx(
        () => Padding(
          padding: AppStyle.edgeInsetsA24,
          child: Row(
            children: [
              Text(
                title,
                style: foucsNode.isFoucsed.value
                    ? AppStyle.textStyleBlack
                    : AppStyle.textStyleWhite,
              ),
              const Spacer(),
              if (foucsNode.isFoucsed.value && items.isNotEmpty)
                Icon(
                  Icons.chevron_left,
                  size: 40.w,
                  color:
                      foucsNode.isFoucsed.value ? Colors.black : Colors.white,
                ),
              AppStyle.hGap12,
              ConstrainedBox(
                constraints: BoxConstraints(minWidth: 120.w),
                child: Text(
                  _valueText,
                  style: foucsNode.isFoucsed.value
                      ? AppStyle.textStyleBlack
                      : AppStyle.textStyleWhite,
                  textAlign: foucsNode.isFoucsed.value
                      ? TextAlign.center
                      : TextAlign.right,
                ),
              ),
              AppStyle.hGap12,
              if (foucsNode.isFoucsed.value && items.isNotEmpty)
                Icon(
                  Icons.chevron_right,
                  size: 40.w,
                  color:
                      foucsNode.isFoucsed.value ? Colors.black : Colors.white,
                ),
            ],
          ),
        ),
      ),
    );
  }
  /// 当前值的显示文本；当前值不在选项内时退回值本身，避免显示空白。
  String get _valueText => items[value] ?? value?.toString() ?? '';

  /// 取当前值的相邻选项，首尾循环。
  ///
  /// 抽成静态纯函数是因为「当前值不在选项列表内」必须被安全处理：该项默认值
  /// 可能来自另一个平台（如 TV 端在桌面调试时读到 libmpv），此时按下左右键
  /// 若按「已收录」计算下标就会越界崩溃。未收录时向右取第一项、向左取最后一项。
  static dynamic pickAdjacentItem({
    required Map<dynamic, String> items,
    required dynamic value,
    required bool forward,
  }) {
    final keys = items.keys.toList();
    final index = keys.indexOf(value);
    if (index < 0) {
      return forward ? keys.first : keys.last;
    }
    if (forward) {
      return index == keys.length - 1 ? keys.first : keys[index + 1];
    }
    return index == 0 ? keys.last : keys[index - 1];
  }

  void showSettingsDialog() {
    Get.dialog(
      AlertDialog(
        backgroundColor: Get.theme.cardColor,
        surfaceTintColor: Colors.transparent,
        title: Text(title, style: AppStyle.titleStyleWhite),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: items.keys.map((e) {
            return ListTile(
              title: Text(items[e] ?? '', style: AppStyle.textStyleWhite),
              contentPadding: AppStyle.edgeInsetsH20,
              autofocus: e == value,
              shape: RoundedRectangleBorder(
                borderRadius: AppStyle.radius16,
              ),
              focusColor: Colors.white54,
              onTap: () {
                onChanged(e);
                Get.back();
              },
            );
          }).toList(),
        ),
      ),
    );
  }
}
