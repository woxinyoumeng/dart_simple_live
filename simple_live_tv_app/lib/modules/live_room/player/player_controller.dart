import 'dart:async';
import 'dart:io';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// 目标缓冲时长（秒）：无论码率高低，都按时间保证这么多秒的缓冲。
///
/// media_kit 的 bufferSize 只映射到字节上限，而 TV 端没有接入该设置（用的是
/// 默认 32MB），高码率直播流下这点字节只够十几秒；TV 端恰是长时间挂机最多的
/// 端，因此必须补上时间维度，让缓冲按「秒」生效而不是按「字节」。
const int _targetBufferSeconds = 20;

/// 把目标缓冲时长换算成字节下限时使用的参考码率（Mbps）。
///
/// mpv 取时间与字节两个上限的先到者：只放宽时间仍会被原来的字节上限提前
/// 截断，时间设置形同虚设，所以字节上限必须按参考码率同步放大。
const int _bufferReferenceBitrateMbps = 20;

/// Mbps 换算成每秒字节数的系数（1 Mbps = 1e6 bit/s，1 字节 = 8 bit）。
const int _bytesPerSecondPerMbps = 1000 * 1000 ~/ 8;

/// 位置冻结判定停滞所需的连续采样次数（6 次采样 ≈ 30 秒）。
///
/// 位置不变既可能是对端断流，也可能只是本地解码卡顿；留出足够长的观察窗口，
/// 才不会因为一次解码抖动就触发重连。
const int _playbackWatchdogStallThreshold = 6;

/// 累计流量不再增长判定停滞所需的连续采样次数（3 次采样 ≈ 15 秒）。
///
/// 位置不变时若连累计流量也停止增长，说明对端已经不再推流（静默断流），
/// 可以比位置判据更早触发恢复，不必白等 30 秒。
const int _playbackNoDataStallThreshold = 3;

/// 播放停滞判定的输入。
class PlaybackStallInput {
  const PlaybackStallInput({
    required this.position,
    required this.previousPosition,
    required this.playing,
    required this.completed,
    required this.inGracePeriod,
    required this.stalledSamples,
    required this.noDataSamples,
    required this.dataUnavailable,
  });

  /// 本次采样到的播放位置。
  final Duration position;

  /// 上一次采样到的播放位置，null 表示首次采样。
  final Duration? previousPosition;

  /// 采样时播放器是否处于 playing 状态。
  final bool playing;

  /// 播放是否已结束。
  final bool completed;

  /// 是否仍在打开播放后的判定宽限期内。
  final bool inGracePeriod;

  /// 包含本次采样在内、连续无进展的采样次数。
  final int stalledSamples;

  /// 包含本次采样在内、连续没有新数据到达的采样次数。
  final int noDataSamples;

  /// 累计流量信号是否不可用（读不到 total-bytes）。
  ///
  /// 不可用时不能把「读不到」当成「没有数据」，否则在不支持该属性的平台上
  /// 会持续误判停滞并反复重连。
  final bool dataUnavailable;
}

/// 看门狗对一次采样的判定结果。
enum PlaybackStallAction {
  /// 无需处理：播放已结束、主动暂停、处于宽限期或未达阈值。
  idle,

  /// 播放位置在推进，播放正常。
  healthy,

  /// 播放位置不再推进且已达阈值，需要交给恢复流程。
  stalled,
}

/// 判定一次播放采样是否停滞。
///
/// 抽成纯函数是因为误判会触发反复重连、代价高，必须能脱离真实播放器验证。
PlaybackStallAction evaluatePlaybackStall(PlaybackStallInput input) {
  // 播放已结束，交给媒体结束流程处理
  if (input.completed) {
    return PlaybackStallAction.idle;
  }
  // 用户或应用主动暂停时位置本来就不动（mpv 缓冲不足用的是 paused-for-cache，不置 pause 属性）
  if (!input.playing) {
    return PlaybackStallAction.idle;
  }
  if (input.inGracePeriod) {
    return PlaybackStallAction.idle;
  }
  if (input.previousPosition == null ||
      input.previousPosition != input.position) {
    return PlaybackStallAction.healthy;
  }
  // 位置冻结是对端断流与本地解码卡顿的共同表现，因此作为兜底判据；
  // 累计流量也不再增长则只可能是对端停止推流，可以更早判定
  final stalled = input.stalledSamples >= _playbackWatchdogStallThreshold ||
      (!input.dataUnavailable &&
          input.noDataSamples >= _playbackNoDataStallThreshold);
  return stalled ? PlaybackStallAction.stalled : PlaybackStallAction.idle;
}

/// 直播追赶的加速倍率。
///
/// ExoPlayer 的 LivePlaybackSpeedControl 官方配置是 ±3%；这里取 5%，收敛更快，
/// 又仍在听不出、看不出差别的范围内。
const double _catchUpRate = 1.05;

/// 开始追赶的缓冲深度水位（秒）。
///
/// 缓冲深度就是画面落后直播源的秒数：低于这个水位属于正常网络抖动，追赶只会
/// 白白变速。
const double _catchUpTriggerSeconds = 15;

/// 停止追赶的缓冲深度水位（秒）。
///
/// 与触发水位拉开一段滞回带：两个水位重合时，深度在阈值附近的小幅抖动会让
/// 速率反复切换。
const double _catchUpReleaseSeconds = 5;

/// 正常播放速率，也是追赶结束后的回落值。
const double _normalPlaybackRate = 1.0;

/// 直播追赶的目标播放速率：1.0 表示正常速度，> 1.0 表示正在加速追赶。
///
/// 只加速不减速：ExoPlayer 的双向控制需要精确的 live edge 时间才能既追又等，
/// FLV 流拿不到这个时间；而减速会让延迟继续增长，与追回延迟的目标正好相反。
///
/// [catchingUp] 是上一次的判定结果，由此形成滞回：深度落在触发与停止水位之间
/// 时保持原状态，速率才不会在阈值附近抖动。
double evaluateLiveCatchUp({
  required double bufferDepthSeconds,
  required bool catchingUp,
}) {
  if (bufferDepthSeconds >= _catchUpTriggerSeconds) {
    return _catchUpRate;
  }
  if (bufferDepthSeconds <= _catchUpReleaseSeconds) {
    return _normalPlaybackRate;
  }
  return catchingUp ? _catchUpRate : _normalPlaybackRate;
}

/// 一次采样到的原始信号。
///
/// 单独抽出来是因为累计流量要异步读取，而判定必须使用同一时刻的状态，
/// 否则会把读属性之后已变化的位置和旧状态混在一起。
class _PlaybackSample {
  const _PlaybackSample({
    required this.position,
    required this.bufferDepth,
    required this.playing,
    required this.completed,
    required this.totalBytes,
  });

  /// 本次采样到的播放位置。
  final Duration position;

  /// 本地缓冲深度：已下载到的时间点减去当前播放位置，负值按零处理。
  ///
  /// 直播是线性播放，缓冲里堆积的秒数就是画面落后直播源的秒数，是判断是否
  /// 需要变速追赶的依据。
  final Duration bufferDepth;

  /// 采样时播放器是否处于 playing 状态。
  final bool playing;

  /// 播放是否已结束。
  final bool completed;

  /// 累计读取字节数，null 表示本次没有可比较的数值（信号不可用）。
  final int? totalBytes;
}

mixin PlayerMixin {
  GlobalKey<VideoState> globalPlayerKey = GlobalKey<VideoState>();
  GlobalKey globalDanmuKey = GlobalKey();

  /// 播放器实例
  late final player = Player(
    configuration: const PlayerConfiguration(
      title: "Simple Live Player",
      // bufferSize:
      //     // media-kit #549
      //     AppSettingsController.instance.playerBufferSize.value * 1024 * 1024,
    ),
  );

  /// 初始化播放器并设置缓冲与 ao 参数
  Future<void> initializePlayer() async {
    var pp = player.platform as NativePlayer;

    await _applyPlaybackBuffer(pp);

    // media_kit 仓库更新导致的问题，临时解决办法
    if (Platform.isAndroid) {
      await pp.setProperty('force-seekable', 'yes');
    }
  }

  /// 按「时间优先」设置播放缓冲。
  ///
  /// media_kit 的 bufferSize 只作用于字节上限，而 TV 端并未接入该设置（用默认
  /// 32MB），高码率流下字节上限换算出的时长很短，会先把时间缓冲截断；mpv 取
  /// 时间与字节两个上限的先到者，所以两个维度必须一起设。
  Future<void> _applyPlaybackBuffer(NativePlayer platform) async {
    const bufferBytes = _targetBufferSeconds *
        _bufferReferenceBitrateMbps *
        _bytesPerSecondPerMbps;
    await platform.setProperty(
      'demuxer-readahead-secs',
      '$_targetBufferSeconds',
    );
    await platform.setProperty('demuxer-max-bytes', '$bufferBytes');
    await platform.setProperty('demuxer-max-back-bytes', '$bufferBytes');
  }

  /// 视频控制器
  late final videoController = VideoController(
    player,
    configuration: AppSettingsController.instance.playerCompatMode.value
        ? const VideoControllerConfiguration(
            vo: 'mediacodec_embed',
            hwdec: 'mediacodec',
          )
        : VideoControllerConfiguration(
            enableHardwareAcceleration:
                AppSettingsController.instance.hardwareDecode.value,
            androidAttachSurfaceAfterVideoParameters: false,
          ),
  );
}
mixin PlayerStateMixin on PlayerMixin {
  /// 是否显示弹幕
  RxBool showDanmakuState = false.obs;

  /// 是否显示控制器
  RxBool showControlsState = false.obs;

  /// 是否显示设置窗口
  RxBool showSettingState = false.obs;

  /// 是否显示弹幕设置窗口
  RxBool showDanmakuSettingState = false.obs;

  /// 是否处于锁定控制器状态
  RxBool lockControlsState = false.obs;

  /// 是否处于全屏状态
  RxBool fullScreenState = false.obs;

  /// 显示手势Tip
  RxBool showGestureTip = false.obs;

  /// 手势Tip文本
  RxString gestureTipText = "".obs;

  /// 显示提示底部Tip
  RxBool showBottomTip = false.obs;

  /// 提示底部Tip文本
  RxString bottomTipText = "".obs;

  /// 自动隐藏控制器计时器
  Timer? hideControlsTimer;

  /// 自动隐藏提示计时器
  Timer? hideSeekTipTimer;

  Widget? danmakuView;

  var showQualites = false.obs;
  var showLines = false.obs;

  /// 隐藏控制器
  void hideControls() {
    showControlsState.value = false;
    hideControlsTimer?.cancel();
  }

  void setLockState() {
    lockControlsState.value = !lockControlsState.value;
    if (lockControlsState.value) {
      showControlsState.value = false;
    } else {
      showControlsState.value = true;
    }
  }

  /// 显示控制器
  void showControls() {
    showControlsState.value = true;
    resetHideControlsTimer();
  }

  /// 开始隐藏控制器计时
  /// - 当点击控制器上时功能时需要重新计时
  void resetHideControlsTimer() {
    hideControlsTimer?.cancel();

    hideControlsTimer = Timer(
      const Duration(
        seconds: 5,
      ),
      hideControls,
    );
  }

  void updateScaleMode() {
    var boxFit = BoxFit.contain;
    double? aspectRatio;
    if (player.state.width != null && player.state.height != null) {
      aspectRatio = player.state.width! / player.state.height!;
    }

    if (AppSettingsController.instance.scaleMode.value == 0) {
      boxFit = BoxFit.contain;
    } else if (AppSettingsController.instance.scaleMode.value == 1) {
      boxFit = BoxFit.fill;
    } else if (AppSettingsController.instance.scaleMode.value == 2) {
      boxFit = BoxFit.cover;
    } else if (AppSettingsController.instance.scaleMode.value == 3) {
      boxFit = BoxFit.contain;
      aspectRatio = 16 / 9;
    } else if (AppSettingsController.instance.scaleMode.value == 4) {
      boxFit = BoxFit.contain;
      aspectRatio = 4 / 3;
    }
    globalPlayerKey.currentState?.update(
      aspectRatio: aspectRatio,
      fit: boxFit,
    );
  }
}
mixin PlayerDanmakuMixin on PlayerStateMixin {
  /// 弹幕控制器
  DanmakuController? danmakuController;

  void initDanmakuController(DanmakuController e) {
    danmakuController = e;
    // danmakuController?.updateOption(
    //   DanmakuOption(
    //     fontSize: AppSettingsController.instance.danmuSize.value.w,
    //     area: AppSettingsController.instance.danmuArea.value,
    //     duration: AppSettingsController.instance.danmuSpeed.value,
    //     opacity: AppSettingsController.instance.danmuOpacity.value,
    //     strokeWidth: AppSettingsController.instance.danmuStrokeWidth.value.w,
    //   ),
    // );
  }

  void updateDanmuOption(DanmakuOption? option) {
    if (danmakuController == null || option == null) return;
    danmakuController!.updateOption(option);
  }

  void disposeDanmakuController() {
    danmakuController?.clear();
  }

  void addDanmaku(List<DanmakuContentItem> items) {
    if (!showDanmakuState.value) {
      return;
    }
    for (var item in items) {
      danmakuController?.addDanmaku(item);
    }
  }
}
mixin PlayerSystemMixin on PlayerMixin, PlayerStateMixin, PlayerDanmakuMixin {
  final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

  /// 初始化一些系统状态
  void initSystem() async {
    // 屏幕常亮
    WakelockPlus.enable();

    // 开始隐藏计时
    resetHideControlsTimer();
  }

  /// 释放一些系统状态
  Future resetSystem() async {
    await WakelockPlus.disable();
  }

  /// 是否是IOS16以下
  Future<bool> beforeIOS16() async {
    if (Platform.isIOS) {
      var info = await deviceInfo.iosInfo;
      var version = info.systemVersion;
      var versionInt = int.tryParse(version.split('.').first) ?? 0;
      return versionInt < 16;
    } else {
      return false;
    }
  }
}

class PlayerController extends BaseController
    with PlayerMixin, PlayerStateMixin, PlayerDanmakuMixin, PlayerSystemMixin {
  @override
  void onInit() {
    initSystem();
    initStream();
    super.onInit();
  }

  var width = 0.obs;
  var height = 0.obs;

  StreamSubscription<String>? _errorSubscription;
  StreamSubscription? _completedSubscription;
  StreamSubscription? _widthSubscription;
  StreamSubscription? _heightSubscription;
  StreamSubscription? _logSubscription;

  /// 播放停滞检测的采样间隔。
  static const Duration _playbackWatchdogInterval = Duration(seconds: 5);

  /// 打开播放后不做停滞判定的宽限时间。
  ///
  /// 刚 open 时 mpv 还没收到数据，位置必然不动；不留宽限期的话，正常的
  /// 起播延迟会被当成断流，刚打开就开始重连。
  static const Duration _playbackWatchdogGracePeriod = Duration(seconds: 20);

  /// 判定播放真正恢复所需的连续健康采样次数（3 次 ≈ 15 秒）。
  ///
  /// 每次打开播放后的第一次采样必然算「位置推进」（没有上一次位置可比），
  /// 单次健康不足以证明恢复，否则 5 秒级的播放抖动会反复把重试预算清零。
  static const int _playbackHealthyStreakThreshold = 3;

  /// mpv 累计流量属性名。
  static const String _totalBytesProperty = "total-bytes";

  /// 读取 mpv 属性失败时的占位值，用于和真实属性值区分。
  static const String _unknownPropertyValue = "unknown";

  /// 播放停滞检测定时器。
  Timer? _playbackWatchdogTimer;

  /// 上一次采样到的播放位置。
  Duration? _lastPlaybackProgress;

  /// 连续判定为停滞的采样次数。
  int _playbackWatchdogStallCount = 0;

  /// 连续「没有新数据到达」的采样次数。
  int _playbackNoDataSampleCount = 0;

  /// 上一次采样到的累计读取字节数，null 表示上一次没拿到可比较的数值。
  int? _lastTotalBytes;

  /// 连续判定为「进度在推进」的采样次数。
  int _playbackHealthyStreak = 0;

  /// 是否正在加速追赶累积的直播延迟（滞回状态，跨采样保留）。
  ///
  /// 深度落在触发与停止水位之间时靠它保持原状态，速率才不会在阈值附近抖动。
  bool _isCatchingUp = false;

  /// 上一次重置看门狗的时间，用于宽限期判断。
  DateTime? _playbackWatchdogResetAt;
  void initStream() {
    _errorSubscription = player.stream.error.listen((event) {
      Log.d("播放器错误：$event");
      if (event.contains('no sound.')) {
        return;
      }
      //SmartDialog.showToast(event);
      mediaError(event);
    });

    _completedSubscription = player.stream.completed.listen((event) {
      if (event) {
        mediaEnd();
      }
    });
    _logSubscription = player.stream.log.listen((event) {
      Log.d("播放器日志：$event");
    });
    _widthSubscription = player.stream.width.listen((event) {
      Log.w(
          'width:$event  W:${(player.state.width)}  H:${(player.state.height)}');
      width.value = event ?? 0;
      // isVertical.value =
      //     (player.state.height ?? 9) > (player.state.width ?? 16);
    });
    _heightSubscription = player.stream.height.listen((event) {
      Log.w(
          'height:$event  W:${(player.state.width)}  H:${(player.state.height)}');
      height.value = event ?? 0;
      // isVertical.value =
      //     (player.state.height ?? 9) > (player.state.width ?? 16);
    });
  }

  void disposeStream() {
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _widthSubscription?.cancel();
    _heightSubscription?.cancel();
    _logSubscription?.cancel();
  }

  /// 重置并启动播放停滞检测。
  ///
  /// 幂等：每次重新打开播放都从头计时，否则上一次打开残留的停滞计数会让
  /// 新的播放刚开始就被判定为停滞，白白耗掉一次重试机会。
  void startPlaybackWatchdog() {
    _playbackWatchdogTimer?.cancel();
    _lastPlaybackProgress = null;
    _playbackWatchdogStallCount = 0;
    _playbackNoDataSampleCount = 0;
    _lastTotalBytes = null;
    _playbackHealthyStreak = 0;
    _playbackWatchdogResetAt = DateTime.now();
    // 新的一轮播放不该继承上一轮的加速速率：重新打开时缓冲深度还没建立，
    // 带着加速速率起播只会让用户觉得声音莫名偏快
    _resetLiveCatchUp();
    Log.d("启动播放停滞检测（宽限 ${_playbackWatchdogGracePeriod.inSeconds} 秒）");
    _playbackWatchdogTimer = Timer.periodic(
      _playbackWatchdogInterval,
      // 采样是异步的（要读累计流量），不等待结果以免阻塞定时器
      (_) => unawaited(_checkPlaybackProgress()),
    );
  }

  /// 停止播放停滞检测。
  void stopPlaybackWatchdog() {
    _playbackWatchdogTimer?.cancel();
    _playbackWatchdogTimer = null;
  }

  /// 是否仍处于打开播放后的停滞判定宽限期内。
  bool get _isInPlaybackWatchdogGracePeriod {
    final resetAt = _playbackWatchdogResetAt;
    return resetAt == null ||
        DateTime.now().difference(resetAt) < _playbackWatchdogGracePeriod;
  }

  /// 检查播放是否停滞。
  ///
  /// 直播流在 CDN 挂起或静默断流时不会产生任何 mpv 事件（既无 EOF 也无 error），
  /// 画面会永久停在最后一帧；这里用「播放位置是否推进」来发现这种情况。
  Future<void> _checkPlaybackProgress() async {
    final sample = await _readPlaybackSample();
    final previous = _lastPlaybackProgress;
    final advanced = previous == null || previous != sample.position;
    _lastPlaybackProgress = sample.position;
    // 上一次拿不到数值时无法比较，只能先当作有新数据，避免开局就误判断流
    final dataAdvanced =
        _lastTotalBytes == null || sample.totalBytes != _lastTotalBytes;
    _lastTotalBytes = sample.totalBytes;
    // 只有「正在播放却位置不变 / 没有新数据」的采样才计入停滞，其余情况立即清零
    final active = sample.playing && !sample.completed;
    _playbackWatchdogStallCount =
        !advanced && active ? _playbackWatchdogStallCount + 1 : 0;
    _playbackNoDataSampleCount =
        !dataAdvanced && active ? _playbackNoDataSampleCount + 1 : 0;
    // 只在真正播放时评估追赶：暂停/结束时位置不动，缓冲深度没有追赶意义；
    // 且追赶要先于停滞处理，因为停滞会重新打开播放，速率重置必须最后生效
    if (active) {
      _applyLiveCatchUp(sample);
    }
    final action = evaluatePlaybackStall(
      PlaybackStallInput(
        position: sample.position,
        previousPosition: previous,
        playing: sample.playing,
        completed: sample.completed,
        inGracePeriod: _isInPlaybackWatchdogGracePeriod,
        stalledSamples: _playbackWatchdogStallCount,
        noDataSamples: _playbackNoDataSampleCount,
        dataUnavailable: sample.totalBytes == null,
      ),
    );
    _applyPlaybackStallAction(action);
  }

  /// 读取一次播放采样信号。
  ///
  /// 累计流量要异步读属性，因此读完后再取状态快照：否则位置可能已经变了，
  /// 判定就会把两个不同时刻的状态混在一起。
  Future<_PlaybackSample> _readPlaybackSample() async {
    final totalBytes = await _readPlayerProperty(_totalBytesProperty);
    final state = player.state;
    // 已下载到的时间点减去当前播放位置；位置越过缓冲末端时按零处理
    final bufferDepth = state.buffer - state.position;
    return _PlaybackSample(
      position: state.position,
      bufferDepth: bufferDepth.isNegative ? Duration.zero : bufferDepth,
      playing: state.playing,
      completed: state.completed,
      // 解析失败与读取失败一样，都代表本次拿不到可比较的数值
      totalBytes:
          totalBytes == _unknownPropertyValue ? null : int.tryParse(totalBytes),
    );
  }

  /// 按缓冲深度调整播放速率，压缩累积的直播延迟。
  ///
  /// 复用 5 秒采样循环，不额外开定时器：追赶是分钟级的慢变量，秒级响应足够。
  /// 目标速率与当前速率相同时不下发，避免每 5 秒重复设置同一个值。
  void _applyLiveCatchUp(_PlaybackSample sample) {
    final bufferDepthSeconds =
        sample.bufferDepth.inMilliseconds / Duration.millisecondsPerSecond;
    final targetRate = evaluateLiveCatchUp(
      bufferDepthSeconds: bufferDepthSeconds,
      catchingUp: _isCatchingUp,
    );
    final alreadyApplied = targetRate == player.state.rate;
    _isCatchingUp = targetRate > _normalPlaybackRate;
    if (alreadyApplied) {
      return;
    }
    // 不等待下发结果：setRate 会排在 media_kit 的命令锁后面（可能正在 open/stop），
    // 等待会把同一轮采样里的停滞判定一起拖住，恢复链不能被一次速率调整延误
    unawaited(
      _applyPlaybackRate(
        targetRate,
        "缓冲深度 ${bufferDepthSeconds.toStringAsFixed(1)} 秒",
      ),
    );
  }

  /// 结束追赶并把播放速率恢复为正常值。
  ///
  /// 速率是播放器级属性、跨 open 保留：不清零的话，重新打开播放会带着上一轮
  /// 的加速速率起播，而那时缓冲深度还没建立，用户只会觉得声音莫名偏快。
  void _resetLiveCatchUp() {
    if (!_isCatchingUp) {
      return;
    }
    _isCatchingUp = false;
    unawaited(_applyPlaybackRate(_normalPlaybackRate, "结束追赶"));
  }

  /// 下发播放速率并记录日志。
  ///
  /// 失败只记日志：速率是压缩延迟的辅助手段，既不能中断采样循环，也不能打断
  /// 断流恢复链；下一次采样还会按同样的水位重试。
  Future<void> _applyPlaybackRate(double rate, String scene) async {
    try {
      await player.setRate(rate);
      Log.w("直播追赶：$scene，播放速率 $rate");
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 按判定结果更新健康计数或触发恢复。
  void _applyPlaybackStallAction(PlaybackStallAction action) {
    switch (action) {
      case PlaybackStallAction.healthy:
        _markPlaybackHealthySample();
      case PlaybackStallAction.stalled:
        _handlePlaybackStalled();
      case PlaybackStallAction.idle:
        // 播放结束、主动暂停、宽限期内或未达阈值：都不算恢复
        _playbackHealthyStreak = 0;
    }
  }

  /// 记录一次「播放进度在推进」的采样。
  ///
  /// 只有连续达到阈值才算恢复：否则每次 open 后的第一次采样就会清空重试
  /// 预算，让重试上限形同虚设。用 == 判断保证一次恢复只回调一次。
  void _markPlaybackHealthySample() {
    _playbackHealthyStreak += 1;
    if (_playbackHealthyStreak == _playbackHealthyStreakThreshold) {
      // onPlaybackHealthy 由直播页覆写且不调用 super，恢复的副作用只能放在
      // 调用点；此刻播放已连续推进，不该再保留上一轮断流前的加速速率
      _resetLiveCatchUp();
      onPlaybackHealthy();
    }
  }

  /// 处理一次判定为停滞的采样。
  void _handlePlaybackStalled() {
    // 停滞说明还没恢复，连续健康计数必须从头开始
    _playbackHealthyStreak = 0;
    _playbackWatchdogStallCount = 0;
    Log.w("播放停滞，尝试恢复");
    mediaStalled();
  }

  /// 播放停滞回调，默认按播放错误处理，子类可覆盖。
  void mediaStalled() {
    mediaError("播放停滞");
  }

  /// 播放是否已恢复正常（子类据此清零重试预算、撤销误报状态）。
  void onPlaybackHealthy() {}

  /// 读取 mpv 属性并转为字符串，失败时返回 unknown。
  Future<String> _readPlayerProperty(String property) async {
    try {
      final platform = player.platform;
      // getProperty 只由 NativePlayer 提供，其他实现没有这个能力
      if (platform is! NativePlayer) {
        return _unknownPropertyValue;
      }
      return await platform.getProperty(property);
    } catch (e) {
      Log.logPrint(e);
      return _unknownPropertyValue;
    }
  }

  void mediaEnd() {}

  void mediaError(String error) {}

  @override
  void onClose() async {
    Log.w("播放器关闭");
    stopPlaybackWatchdog();
    disposeStream();
    disposeDanmakuController();
    await resetSystem();
    await player.dispose();
    super.onClose();
  }
}
