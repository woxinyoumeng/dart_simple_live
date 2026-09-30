import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';

/// 判定停滞所需的连续无进展采样次数。
///
/// 需与 player_controller.dart 中的 _playbackWatchdogStallThreshold 一致：
/// 该常量是库私有的，测试只能按同样的数值构造边界用例。
const int _stallThreshold = 6;

/// 判定静默断流所需的连续「没有新数据到达」采样次数。
///
/// 同样需与 player_controller.dart 中的 _playbackNoDataStallThreshold 一致：
/// 该常量是库私有的，测试只能按同样的数值构造边界用例。
const int _noDataThreshold = 3;

/// 构造一次播放采样输入，默认是「正常播放但位置未推进」的场景。
PlaybackStallInput _input({
  Duration? previousPosition = const Duration(seconds: 10),
  Duration position = const Duration(seconds: 10),
  bool playing = true,
  bool completed = false,
  bool inGracePeriod = false,
  int stalledSamples = 1,
  int noDataSamples = 0,
  bool dataUnavailable = false,
}) {
  return PlaybackStallInput(
    position: position,
    previousPosition: previousPosition,
    playing: playing,
    completed: completed,
    inGracePeriod: inGracePeriod,
    stalledSamples: stalledSamples,
    noDataSamples: noDataSamples,
    dataUnavailable: dataUnavailable,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("evaluatePlaybackStall", () {
    test("播放位置正常推进时判定为健康", () {
      final action = evaluatePlaybackStall(
        _input(
          previousPosition: const Duration(seconds: 10),
          position: const Duration(seconds: 15),
          stalledSamples: 0,
        ),
      );
      expect(action, PlaybackStallAction.healthy);
    });

    test("首次采样（没有上一次位置）时视为进度推进", () {
      final action = evaluatePlaybackStall(
        _input(previousPosition: null, stalledSamples: 0),
      );
      expect(action, PlaybackStallAction.healthy);
    });

    test("连续停滞达到阈值时判定为停滞", () {
      final action = evaluatePlaybackStall(
        _input(stalledSamples: _stallThreshold),
      );
      expect(action, PlaybackStallAction.stalled);
    });

    test("连续停滞未达阈值时不触发恢复", () {
      final action = evaluatePlaybackStall(
        _input(stalledSamples: _stallThreshold - 1),
      );
      expect(action, PlaybackStallAction.idle);
    });

    test("暂停状态下即使位置不动也不判定停滞", () {
      final action = evaluatePlaybackStall(
        _input(playing: false, stalledSamples: _stallThreshold),
      );
      expect(action, PlaybackStallAction.idle);
    });

    test("播放已结束时交给媒体结束流程处理", () {
      final action = evaluatePlaybackStall(
        _input(completed: true, stalledSamples: _stallThreshold),
      );
      expect(action, PlaybackStallAction.idle);
    });

    test("宽限期内不判定停滞", () {
      final action = evaluatePlaybackStall(
        _input(inGracePeriod: true, stalledSamples: _stallThreshold),
      );
      expect(action, PlaybackStallAction.idle);
    });

    test("位置未推进但持续有新数据到达时不判定停滞", () {
      // 累计流量还在增长说明对端仍在推流，位置不动只是本地解码慢，
      // 这种情况交给位置冻结阈值兜底，不应提前断流重连
      final action = evaluatePlaybackStall(
        _input(stalledSamples: _stallThreshold - 1, noDataSamples: 0),
      );
      expect(action, PlaybackStallAction.idle);
    });

    test("位置未推进且连续无新数据达阈值时判定为停滞", () {
      // 未达无数据阈值时仍不动
      expect(
        evaluatePlaybackStall(_input(noDataSamples: _noDataThreshold - 1)),
        PlaybackStallAction.idle,
      );
      // 位置冻结远未达阈值，但累计流量已停止增长：对端不再推流，提前恢复
      final action = evaluatePlaybackStall(
        _input(stalledSamples: 0, noDataSamples: _noDataThreshold),
      );
      expect(action, PlaybackStallAction.stalled);
    });

    test("累计流量信号不可用时不按无数据判定停滞", () {
      // 读不到 total-bytes 的实现不能把「读不到」当成「没数据」，
      // 否则会对这些平台持续误判停滞并反复重连
      final action = evaluatePlaybackStall(
        _input(
          stalledSamples: _stallThreshold - 1,
          noDataSamples: _noDataThreshold * 10,
          dataUnavailable: true,
        ),
      );
      expect(action, PlaybackStallAction.idle);
    });
  });
}
