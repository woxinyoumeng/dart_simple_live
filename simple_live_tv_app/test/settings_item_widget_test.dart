import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_tv_app/widgets/settings_item_widget.dart';

void main() {
  group('SettingsItemWidget.pickAdjacentItem', () {
    const items = {
      'no': 'no',
      'auto': 'auto',
      'auto-safe': 'auto-safe',
    };

    test('中间值按方向取相邻项', () {
      expect(
        SettingsItemWidget.pickAdjacentItem(
          items: items,
          value: 'auto',
          forward: true,
        ),
        'auto-safe',
      );
      expect(
        SettingsItemWidget.pickAdjacentItem(
          items: items,
          value: 'auto',
          forward: false,
        ),
        'no',
      );
    });

    test('首尾项按方向循环', () {
      expect(
        SettingsItemWidget.pickAdjacentItem(
          items: items,
          value: 'auto-safe',
          forward: true,
        ),
        'no',
      );
      expect(
        SettingsItemWidget.pickAdjacentItem(
          items: items,
          value: 'no',
          forward: false,
        ),
        'auto-safe',
      );
    });

    test('当前值不在选项内时不越界，按未收录处理', () {
      // 例如 TV 端在桌面平台调试读到 libmpv，而列表只收录了 Android 驱动
      expect(
        SettingsItemWidget.pickAdjacentItem(
          items: items,
          value: 'libmpv',
          forward: true,
        ),
        'no',
      );
      expect(
        SettingsItemWidget.pickAdjacentItem(
          items: items,
          value: 'libmpv',
          forward: false,
        ),
        'auto-safe',
      );
    });

    test('单元素列表两个方向都回到自身', () {
      const single = {'gpu': 'gpu'};
      expect(
        SettingsItemWidget.pickAdjacentItem(
          items: single,
          value: 'gpu',
          forward: true,
        ),
        'gpu',
      );
      expect(
        SettingsItemWidget.pickAdjacentItem(
          items: single,
          value: 'gpu',
          forward: false,
        ),
        'gpu',
      );
    });
  });
}
