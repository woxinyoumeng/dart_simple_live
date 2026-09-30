import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 结果与用例构造时刻之间允许的误差（秒）：解析内部会重新取一次当前时间。
const int _toleranceSeconds = 5;

/// 当前 Unix 秒，用于构造绝对过期时刻。
int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  group("parsePlayUrlExpireSeconds", () {
    test("相对剩余秒数原样返回", () {
      expect(
        parsePlayUrlExpireSeconds(
          "https://cdn.example.com/live.flv?expire=300&sign=a",
        ),
        300,
      );
    });

    test("绝对 Unix 秒换算成剩余秒数", () {
      final expireAt = _nowSeconds() + 3600;
      expect(
        parsePlayUrlExpireSeconds(
          "https://cdn.example.com/live.flv?expire=$expireAt&sign=a",
        ),
        inInclusiveRange(3600 - _toleranceSeconds, 3600 + _toleranceSeconds),
      );
    });

    test("已经过期的绝对时间戳返回 null", () {
      final expireAt = _nowSeconds() - 10;
      expect(
        parsePlayUrlExpireSeconds(
          "https://cdn.example.com/live.flv?expire=$expireAt&sign=a",
        ),
        isNull,
      );
    });

    test("虎牙十六进制 wsTime 的绝对过期时刻换算成剩余秒数", () {
      final expireAt = _nowSeconds() + 21600;
      expect(
        parsePlayUrlExpireSeconds(
          "https://cdn.example.com/live.flv?wsTime=${expireAt.toRadixString(16)}",
        ),
        inInclusiveRange(21600 - _toleranceSeconds, 21600 + _toleranceSeconds),
      );
    });

    test("虎牙十六进制 wsTime 的相对秒数按原值处理", () {
      // 0x258 = 600：远不到一天，只能解释为相对剩余秒数
      expect(
        parsePlayUrlExpireSeconds(
          "https://cdn.example.com/live.flv?wsTime=258",
        ),
        600,
      );
    });

    test("同时带 expire 与 wsTime 时以 expire 为准", () {
      final wsTime = (_nowSeconds() + 21600).toRadixString(16);
      expect(
        parsePlayUrlExpireSeconds(
          "https://cdn.example.com/live.flv?expire=300&wsTime=$wsTime",
        ),
        300,
      );
    });

    test("恰好一天仍按相对秒数处理", () {
      // 86400 是「相对秒数」与「绝对时刻」的分界值本身：分界值不能溢出成绝对时刻
      expect(
        parsePlayUrlExpireSeconds(
          "https://cdn.example.com/live.flv?expire=86400",
        ),
        86400,
      );
    });

    test("没有有效期参数时返回 null", () {
      expect(
        parsePlayUrlExpireSeconds("https://cdn.example.com/live.flv"),
        isNull,
      );
    });

    test("空字符串返回 null", () {
      expect(parsePlayUrlExpireSeconds(""), isNull);
    });

    test("null 返回 null", () {
      expect(parsePlayUrlExpireSeconds(null), isNull);
    });

    test("非数字的 expire 返回 null", () {
      expect(
        parsePlayUrlExpireSeconds(
          "https://cdn.example.com/live.flv?expire=abc",
        ),
        isNull,
      );
    });

    test("expire 与 wsTime 都无法解析时返回 null", () {
      expect(
        parsePlayUrlExpireSeconds(
          "https://cdn.example.com/live.flv?expire=abc&wsTime=zz",
        ),
        isNull,
      );
    });

    test("剩余秒数不是正数时返回 null", () {
      expect(
        parsePlayUrlExpireSeconds("https://cdn.example.com/live.flv?expire=0"),
        isNull,
      );
      expect(
        parsePlayUrlExpireSeconds("https://cdn.example.com/live.flv?expire=-5"),
        isNull,
      );
    });
  });
}
