import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';

/// 开始追赶的缓冲深度水位（秒）。
///
/// 需与 player_controller.dart 中的 _catchUpTriggerSeconds 一致：该常量是库私有
/// 的，测试只能按同样的数值构造边界用例。
const double _triggerSeconds = 15;

/// 停止追赶的缓冲深度水位（秒）。
///
/// 同样需与 player_controller.dart 中的 _catchUpReleaseSeconds 一致。
const double _releaseSeconds = 5;

/// 追赶时的加速倍率。
///
/// 同样需与 player_controller.dart 中的 _catchUpRate 一致。
const double _catchUpRate = 1.05;

/// 正常播放速率，同样需与 player_controller.dart 中的 _normalPlaybackRate 一致。
const double _normalRate = 1.0;

/// 判定一次追赶，避免用例里重复堆参数。
double _evaluate({required double depth, required bool catchingUp}) {
  return evaluateLiveCatchUp(
    bufferDepthSeconds: depth,
    catchingUp: catchingUp,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("evaluateLiveCatchUp", () {
    test("缓冲深度低于触发水位且未追赶时保持正常速率", () {
      expect(
        _evaluate(depth: _triggerSeconds - 1, catchingUp: false),
        _normalRate,
      );
    });

    test("缓冲深度达到触发水位且未追赶时开始加速追赶", () {
      expect(
        _evaluate(depth: _triggerSeconds, catchingUp: false),
        _catchUpRate,
      );
    });

    test("追赶中缓冲深度仍在触发水位以上时继续追赶", () {
      expect(
        _evaluate(depth: _triggerSeconds + 5, catchingUp: true),
        _catchUpRate,
      );
    });

    test("追赶中缓冲深度降到停止水位时恢复正常速率", () {
      expect(
        _evaluate(depth: _releaseSeconds, catchingUp: true),
        _normalRate,
      );
    });

    test("追赶中缓冲深度落在滞回区间时保持追赶，不来回抖动", () {
      expect(
        _evaluate(depth: _releaseSeconds + 1, catchingUp: true),
        _catchUpRate,
      );
    });

    test("未追赶时缓冲深度落在滞回区间不触发加速", () {
      expect(
        _evaluate(depth: _releaseSeconds + 1, catchingUp: false),
        _normalRate,
      );
    });
  });
}
