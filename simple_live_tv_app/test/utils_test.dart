import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_tv_app/app/utils.dart';

void main() {
  group('Utils.liveDurationToString', () {
    /// 以当前时刻为基准生成 N 秒前的开播时间戳字符串。
    String secondsAgo(int seconds) =>
        '${DateTime.now().millisecondsSinceEpoch ~/ 1000 - seconds}';

    test('空值、占位值与非法值一律返回空串', () {
      expect(Utils.liveDurationToString(null), '');
      expect(Utils.liveDurationToString(''), '');
      expect(Utils.liveDurationToString('0'), '');
      expect(Utils.liveDurationToString('abc'), '');
    });

    test('不足一分钟返回提示文案', () {
      expect(Utils.liveDurationToString(secondsAgo(0)), '不足1分钟');
      expect(Utils.liveDurationToString(secondsAgo(59)), '不足1分钟');
    });

    test('满一分钟后按分钟展示', () {
      expect(Utils.liveDurationToString(secondsAgo(90)), '1分钟');
      expect(Utils.liveDurationToString(secondsAgo(3599)), '59分钟');
    });

    test('满一小时后按小时分钟展示', () {
      expect(Utils.liveDurationToString(secondsAgo(3600)), '1小时');
      expect(Utils.liveDurationToString(secondsAgo(3900)), '1小时5分钟');
      expect(Utils.liveDurationToString(secondsAgo(7200)), '2小时');
    });
  });
}
