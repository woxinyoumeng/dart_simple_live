import 'dart:async';
import 'dart:io';

import 'package:auto_orientation_v2/auto_orientation_v2.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:floating/floating.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/custom_throttle.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

/// 1MB 对应的字节数。播放器缓冲区按 MB 配置，media_kit 需要字节数。
const int _megabyteInBytes = 1024 * 1024;

/// 目标缓冲时长（秒）：无论码率高低，都按时间保证这么多秒的缓冲。
///
/// media_kit 只把 bufferSize 映射到字节维度（demuxer-max-bytes /
/// demuxer-max-back-bytes），而字节维度在高码率下会退化：20 Mbps 的流里
/// 32MB 只够十几秒，抗抖动能力随码率下降；补上时间维度，缓冲才会按「秒」
/// 生效，而不是按「字节」。
const int _targetBufferSeconds = 20;

/// 把目标缓冲时长换算成字节下限时使用的参考码率（Mbps）。
///
/// 它的作用只是给出字节下限：时间与字节两个上限 mpv 取先到者，只放宽
/// 时间仍会被原来的字节上限提前截断，时间设置形同虚设，因此字节下限必须
/// 同步放大。
const int _bufferReferenceBitrateMbps = 20;

/// Mbps 换算成每秒字节数的系数（1 Mbps = 1e6 bit/s，1 字节 = 8 bit）。
const int _bytesPerSecondPerMbps = 1000 * 1000 ~/ 8;

/// 不设置 ffmpeg 流层重连参数（stream-lavf-o）。
///
/// 曾打开过 reconnect_streamed / reconnect_at_eof，让 ffmpeg 自己重连同一个直播地址；
/// 实测在 HTTP-FLV 直播上会让时间戳不连续（mpv 报 Concatenated FLV / Packet mismatch，
/// 画面与声音反复抖动），因为重连拿到的是新的时间轴。
/// 断流改由应用层恢复链处理：它会重新申请一个地址，时间轴是干净的。

/// 连续判定为停滞的次数，达到后触发恢复流程（约 30 秒无进展）。
const int _playbackWatchdogStallThreshold = 6;

/// 连续「没有新数据到达」的采样次数，达到后即判定停滞（3 次约 15 秒）。
///
/// 位置不变可能只是解码卡顿；若连累计流量也不再增长，说明对端已经不再推流，
/// 属于静默断流（连接仍在、没有任何 mpv 事件），可以比位置判据更早触发恢复。
const int _playbackNoDataStallThreshold = 3;

/// 页面关闭后延迟销毁播放器的时间。
///
/// mpv 的结束流程是异步的：若在事件回调仍在执行时销毁播放器，mpv 线程
/// 可能访问已关闭的 Dart FFI 回调（media_kit #1443），触发 SIGABRT/SIGSEGV。
/// 因此先停止播放，等待片刻后再销毁。
const Duration _playerDisposeDelay = Duration(seconds: 1);

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

  /// 播放器的 playing 状态。
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
  /// 不可用时不能把「读不到」当成「没有数据」，否则会在不支持该属性的
  /// 平台上一直误判停滞。
  final bool dataUnavailable;
}

/// 看门狗对一次采样的判定结果。
enum PlaybackStallAction {
  /// 无需处理：播放已结束、主动暂停、处于宽限期或未达到停滞阈值。
  idle,

  /// 播放位置在推进，播放正常。
  healthy,

  /// 播放位置不再推进且已达阈值，需要走恢复流程。
  stalled,
}

/// 判定一次播放采样结果。
///
/// 抽成纯函数是为了覆盖各种暂停/结束/宽限组合：误判会触发反复重连，
/// 代价高，必须能脱离真实播放器验证。
PlaybackStallAction evaluatePlaybackStall(PlaybackStallInput input) {
  // 播放已结束，交给媒体结束流程处理
  if (input.completed) {
    return PlaybackStallAction.idle;
  }
  // 用户或应用主动暂停（mpv 缓冲不足时用的是 paused-for-cache，不置 pause 属性）
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
  // 累计流量也不再增长则只可能是对端不再推流，可以更早判定
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
/// 单独抽出来是因为累计流量要异步读取，而判定必须用「同一个时刻」的状态，
/// 否则会把读完属性后已变化的位置与旧状态混在一起。
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

  /// 本次采样时播放器是否处于 playing 状态。
  final bool playing;

  /// 播放是否已结束。
  final bool completed;

  /// 累计读取字节数，null 表示本次没有可比较的数值（信号不可用）。
  final int? totalBytes;
}

mixin PlayerMixin {
  GlobalKey<VideoState> globalPlayerKey = GlobalKey<VideoState>();

  /// 播放器实例
  late final player = Player(
    configuration: PlayerConfiguration(
      title: "Simple Live Player",
      logLevel: AppSettingsController.instance.logEnable.value
          ? MPVLogLevel.info
          : MPVLogLevel.error,
      // 缓冲区大小按 MB 配置，这里换算成 media_kit 需要的字节数
      bufferSize: AppSettingsController.instance.playerBufferSize.value *
          _megabyteInBytes,
    ),
  );

  /// 初始化播放器并设置缓冲与 ao 参数
  Future<void> initializePlayer() async {
    var pp = player.platform as NativePlayer;
    // network-timeout 不在这里覆盖：media_kit 默认属性表已设置 5 秒
    // （real.dart），覆盖成更大的值反而会拖慢断流检测
    // 设置音频输出驱动
    if (AppSettingsController.instance.customPlayerOutput.value) {
      if (player.platform is NativePlayer) {
        await (player.platform as dynamic).setProperty(
          'ao',
          AppSettingsController.instance.audioOutputDriver.value,
        );
      }
    }
    if (player.platform is NativePlayer) {
      await _applyPlaybackBuffer(pp);
    }
    // media_kit 仓库更新导致的问题，临时解决办法
    if (Platform.isAndroid) {
      await pp.setProperty('force-seekable', 'yes');
    }
  }

  /// 按「时间优先」设置播放缓冲。
  ///
  /// media_kit 的 bufferSize 只能定字节上限，字节上限在高码率下换算出的时长
  /// 很短，所以这里显式补上时间维度（demuxer-readahead-secs）；又因为 mpv 取
  /// 时间与字节两个上限的先到者，字节上限必须同步放大到「目标时长 × 参考
  /// 码率」，否则缓冲会先被字节截断，时间设置不生效。
  ///
  /// 用户设置的 MB 更大时以用户为准，不改变设置项本身的含义。
  Future<void> _applyPlaybackBuffer(NativePlayer platform) async {
    final userBufferBytes =
        AppSettingsController.instance.playerBufferSize.value *
            _megabyteInBytes;
    const timeBasedBufferBytes = _targetBufferSeconds *
        _bufferReferenceBitrateMbps *
        _bytesPerSecondPerMbps;
    final bufferBytes = userBufferBytes > timeBasedBufferBytes
        ? userBufferBytes
        : timeBasedBufferBytes;
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
    configuration: AppSettingsController.instance.customPlayerOutput.value
        ? VideoControllerConfiguration(
            vo: AppSettingsController.instance.videoOutputDriver.value,
            hwdec: AppSettingsController.instance.videoHardwareDecoder.value,
          )
        : AppSettingsController.instance.playerCompatMode.value
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
  ///音量控制条计时器
  Timer? hidevolumeTimer;

  /// 是否进入桌面端小窗
  RxBool smallWindowState = false.obs;

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

  /// 是否为竖屏直播间
  var isVertical = false.obs;

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

    hideControlsTimer = Timer(const Duration(seconds: 5), hideControls);
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
    globalPlayerKey.currentState?.update(aspectRatio: aspectRatio, fit: boxFit);
  }
}

mixin PlayerDanmakuMixin on PlayerStateMixin {
  /// 弹幕控制器
  DanmakuController? danmakuController;

  void initDanmakuController(DanmakuController e) {
    danmakuController = e;
    // danmakuController?.updateOption(
    //   DanmakuOption(
    //     fontSize: AppSettingsController.instance.danmuSize.value,
    //     area: AppSettingsController.instance.danmuArea.value,
    //     duration: AppSettingsController.instance.danmuSpeed.value,
    //     opacity: AppSettingsController.instance.danmuOpacity.value,
    //     strokeWidth: AppSettingsController.instance.danmuStrokeWidth.value,
    //     fontWeight: FontWeight
    //         .values[AppSettingsController.instance.danmuFontWeight.value],
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

  final pip = Floating();
  StreamSubscription<PiPStatus>? _pipSubscription;

  //final VolumeController volumeController = VolumeController();

  /// 初始化一些系统状态
  void initSystem() async {
    if (Platform.isAndroid || Platform.isIOS) {
      VolumeController.instance.showSystemUI = false;
    }

    // 屏幕常亮
    //WakelockPlus.enable();

    // 开始隐藏计时
    resetHideControlsTimer();

    // 进入全屏模式
    if (AppSettingsController.instance.autoFullScreen.value) {
      enterFullScreen();
    }
  }

  /// 释放一些系统状态
  Future resetSystem() async {
    _pipSubscription?.cancel();
    //pip.dispose();
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );

    await setPortraitOrientation();
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      // 亮度重置,桌面平台可能会报错,暂时不处理桌面平台的亮度
      try {
        await ScreenBrightness.instance.resetApplicationScreenBrightness();
      } catch (e) {
        Log.logPrint(e);
      }
    }

    await WakelockPlus.disable();
  }

  /// 进入全屏
  void enterFullScreen() {
    fullScreenState.value = true;
    if (Platform.isAndroid || Platform.isIOS) {
      //全屏
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      if (!isVertical.value) {
        //横屏
        setLandscapeOrientation();
      }
    } else {
      windowManager.setFullScreen(true);
    }
    //danmakuController?.clear();
  }

  /// 退出全屏
  void exitFull() {
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
        overlays: SystemUiOverlay.values,
      );
      setPortraitOrientation();
    } else {
      windowManager.setFullScreen(false);
    }
    fullScreenState.value = false;

    //danmakuController?.clear();
  }

  Size? _lastWindowSize;
  Offset? _lastWindowPosition;

  ///小窗模式()
  void enterSmallWindow() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      fullScreenState.value = true;
      smallWindowState.value = true;

      // 读取窗口大小
      _lastWindowSize = await windowManager.getSize();
      _lastWindowPosition = await windowManager.getPosition();

      windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      // 获取视频窗口大小
      var width = player.state.width ?? 16;
      var height = player.state.height ?? 9;

      // 横屏还是竖屏
      if (height > width) {
        var aspectRatio = width / height;
        windowManager.setSize(Size(400, 400 / aspectRatio));
      } else {
        var aspectRatio = height / width;
        windowManager.setSize(Size(280 / aspectRatio, 280));
      }

      windowManager.setAlwaysOnTop(true);
    }
  }

  ///退出小窗模式()
  void exitSmallWindow() {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      fullScreenState.value = false;
      smallWindowState.value = false;
      windowManager.setTitleBarStyle(TitleBarStyle.normal);
      windowManager.setSize(_lastWindowSize!);
      windowManager.setPosition(_lastWindowPosition!);
      windowManager.setAlwaysOnTop(false);
      //windowManager.setAlignment(Alignment.center);
    }
  }

  /// 设置横屏
  Future setLandscapeOrientation() async {
    if (await beforeIOS16()) {
      AutoOrientation.landscapeAutoMode();
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  /// 设置竖屏
  Future setPortraitOrientation() async {
    if (await beforeIOS16()) {
      AutoOrientation.portraitAutoMode();
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
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

  Future saveScreenshot() async {
    try {
      SmartDialog.showLoading(msg: "正在保存截图");
      //检查相册权限,仅iOS需要
      var permission = await Utils.checkPhotoPermission();
      if (!permission) {
        SmartDialog.showToast("没有相册权限");
        SmartDialog.dismiss(status: SmartStatus.loading);
        return;
      }

      var imageData = await player.screenshot();
      if (imageData == null) {
        SmartDialog.showToast("截图失败,数据为空");
        SmartDialog.dismiss(status: SmartStatus.loading);
        return;
      }

      if (Platform.isIOS || Platform.isAndroid) {
        await ImageGallerySaverPlus.saveImage(imageData);
        SmartDialog.showToast("已保存截图至相册");
      } else {
        //选择保存文件夹
        var path = await FilePicker.platform.saveFile(
          allowedExtensions: ["jpg"],
          type: FileType.image,
          fileName: "${DateTime.now().millisecondsSinceEpoch}.jpg",
        );
        if (path == null) {
          SmartDialog.showToast("取消保存");
          SmartDialog.dismiss(status: SmartStatus.loading);
          return;
        }
        var file = File(path);
        await file.writeAsBytes(imageData);
        SmartDialog.showToast("已保存截图至${file.path}");
      }
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("截图失败");
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 小窗开启前弹幕状态
  bool danmakuStateBeforePIP = false;

  /// 弹幕显示状态是否已为小窗暂存。
  ///
  /// 重复开启小窗时不能再记录：那时 [showDanmakuState] 已被置为隐藏，
  /// 再记录会让退出小窗时"恢复"成隐藏，弹幕从此不再出现。
  bool isDanmakuStateSavedForPIP = false;

  Future enablePIP() async {
    if (!Platform.isAndroid) {
      return;
    }
    if (await pip.isPipAvailable == false) {
      SmartDialog.showToast("设备不支持小窗播放");
      return;
    }
    if (!isDanmakuStateSavedForPIP) {
      danmakuStateBeforePIP = showDanmakuState.value;
      isDanmakuStateSavedForPIP = true;
      //关闭并清除弹幕
      if (AppSettingsController.instance.pipHideDanmu.value &&
          danmakuStateBeforePIP) {
        showDanmakuState.value = false;
      }
    }
    danmakuController?.clear();
    //关闭控制器
    showControlsState.value = false;

    //监听事件
    var width = player.state.width ?? 0;
    var height = player.state.height ?? 0;
    Rational ratio = const Rational.landscape();
    if (height > width) {
      ratio = const Rational.vertical();
    } else {
      ratio = const Rational.landscape();
    }
    try {
      await pip.enable(ImmediatePiP(aspectRatio: ratio));
    } catch (e) {
      // 开启失败时恢复弹幕，否则显示状态会一直停留在隐藏
      Log.w("开启小窗播放失败：$e");
      restoreDanmakuAfterPIP();
      rethrow;
    }

    _pipSubscription ??= pip.pipStatusStream.listen((event) {
      if (event == PiPStatus.disabled) {
        restoreDanmakuAfterPIP();
      }
      Log.w(event.toString());
    });
  }

  /// 小窗结束或开启失败后恢复弹幕显示状态。
  ///
  /// 只在确实为小窗暂存过状态时生效，避免干扰用户手动切换的弹幕开关。
  void restoreDanmakuAfterPIP() {
    if (!isDanmakuStateSavedForPIP) {
      return;
    }
    isDanmakuStateSavedForPIP = false;
    danmakuController?.clear();
    showDanmakuState.value = danmakuStateBeforePIP;
  }
}

mixin PlayerGestureControlMixin
    on PlayerStateMixin, PlayerMixin, PlayerSystemMixin {
  /// 单击显示/隐藏控制器
  void onTap() {
    if (showControlsState.value) {
      hideControls();
    } else {
      showControls();
    }
  }

  //桌面端操控
  void onEnter(PointerEnterEvent event) {
    if (!showControlsState.value) {
      showControls();
    }
  }

  void onExit(PointerExitEvent event) {
    if (showControlsState.value) {
      hideControls();
    }
  }

  void onHover(PointerHoverEvent event, BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final targetPosition = screenHeight * 0.25; // 计算屏幕顶部25%的位置
    if (event.position.dy <= targetPosition ||
        event.position.dy >= targetPosition * 3) {
      if (!showControlsState.value) {
        showControls();
      }
    }
  }

  /// 双击全屏/退出全屏
  void onDoubleTap(TapDownDetails details) {
    if (lockControlsState.value) {
      return;
    }
    if (fullScreenState.value) {
      exitFull();
    } else {
      enterFullScreen();
    }
  }

  bool verticalDragging = false;
  bool leftVerticalDrag = false;
  var _currentVolume = 0.0;
  var _currentBrightness = 1.0;
  var verStartPosition = 0.0;

  DelayedThrottle? throttle;

  /// 竖向手势开始
  void onVerticalDragStart(DragStartDetails details) async {
    if (lockControlsState.value && fullScreenState.value) {
      return;
    }

    final dy = details.globalPosition.dy;
    // 开始位置必须是中间2/4的位置
    if (dy < Get.height * 0.25 || dy > Get.height * 0.75) {
      return;
    }

    verStartPosition = dy;
    leftVerticalDrag = details.globalPosition.dx < Get.width / 2;

    throttle = DelayedThrottle(200);

    verticalDragging = true;
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      showGestureTip.value = true;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      _currentVolume = await VolumeController.instance.getVolume();
    }
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      _currentBrightness = await ScreenBrightness.instance.application;
    }
  }

  /// 竖向手势更新
  void onVerticalDragUpdate(DragUpdateDetails e) async {
    if (lockControlsState.value && fullScreenState.value) {
      return;
    }
    if (verticalDragging == false) return;
    if (!Platform.isAndroid && !Platform.isIOS) {
      return;
    }
    //String text = "";
    //double value = 0.0;

    Log.logPrint("$verStartPosition/${e.globalPosition.dy}");

    if (leftVerticalDrag) {
      setGestureBrightness(e.globalPosition.dy);
    } else {
      setGestureVolume(e.globalPosition.dy);
    }
  }

  int lastVolume = -1; // it's ok to be -1

  void setGestureVolume(double dy) {
    double value = 0.0;
    double seek;
    if (dy > verStartPosition) {
      value = ((dy - verStartPosition) / (Get.height * 0.5));

      seek = _currentVolume - value;
      if (seek < 0) {
        seek = 0;
      }
    } else {
      value = ((dy - verStartPosition) / (Get.height * 0.5));
      seek = value.abs() + _currentVolume;
      if (seek > 1) {
        seek = 1;
      }
    }
    int volume = _convertVolume((seek * 100).round());
    if (volume == lastVolume) {
      return;
    }
    lastVolume = volume;
    // update UI outside throttle to make it more fluent
    gestureTipText.value = "音量 $volume%";
    throttle?.invoke(() async => await _realSetVolume(volume));
  }

  // 0 to 100, 5 step each
  int _convertVolume(int volume) {
    return (volume / 5).round() * 5;
  }

  Future _realSetVolume(int volume) async {
    Log.logPrint(volume);
    VolumeController.instance.setVolume(volume / 100);
  }

  void setGestureBrightness(double dy) {
    double value = 0.0;
    if (dy > verStartPosition) {
      value = ((dy - verStartPosition) / (Get.height * 0.5));

      var seek = _currentBrightness - value;
      if (seek < 0) {
        seek = 0;
      }
      ScreenBrightness.instance.setApplicationScreenBrightness(seek);

      gestureTipText.value = "亮度 ${(seek * 100).toInt()}%";
      Log.logPrint(value);
    } else {
      value = ((dy - verStartPosition) / (Get.height * 0.5));
      var seek = value.abs() + _currentBrightness;
      if (seek > 1) {
        seek = 1;
      }

      ScreenBrightness.instance.setApplicationScreenBrightness(seek);
      gestureTipText.value = "亮度 ${(seek * 100).toInt()}%";
      Log.logPrint(value);
    }
  }

  /// 竖向手势完成
  void onVerticalDragEnd(DragEndDetails details) async {
    if (lockControlsState.value && fullScreenState.value) {
      return;
    }
    throttle = null;
    verticalDragging = false;
    leftVerticalDrag = false;
    showGestureTip.value = false;
  }
}

class PlayerController extends BaseController
    with
        PlayerMixin,
        PlayerStateMixin,
        PlayerDanmakuMixin,
        PlayerSystemMixin,
        PlayerGestureControlMixin {
  @override
  void onInit() {
    initSystem();
    initStream();
    //设置音量
    player.setVolume(AppSettingsController.instance.playerVolume.value);
    super.onInit();
  }

  StreamSubscription<String>? _errorSubscription;

  /// 播放停滞检测间隔。
  static const Duration _playbackWatchdogInterval = Duration(seconds: 5);

  /// 打开播放后不做停滞判定的宽限时间。
  static const Duration _playbackWatchdogGracePeriod = Duration(seconds: 20);

  /// 判定播放真正恢复所需的连续健康采样次数（3 次约 15 秒）。
  ///
  /// 单次「位置在推进」不足以说明恢复：每次打开播放后的第一次采样必然算推进
  /// （没有上一次位置可比），若据此立刻清零重试预算，30 次重试上限就会被
  /// 5 秒级的播放抖动反复重置而失效。因此要求连续多次采样都在推进才回调。
  static const int _playbackHealthyStreakThreshold = 3;

  /// 播放器操作进入队列后延迟执行的时间，用于跳出 mpv 当前的事件处理流程。
  static const Duration _playerOperationDelay = Duration(milliseconds: 100);

  /// 单次播放器操作的超时时间。
  ///
  /// mpv 可能因等待网络数据而不响应命令，超时后跳过本次操作，
  /// 避免单个操作卡死整个串行队列。
  static const Duration _playerOperationTimeout = Duration(seconds: 15);

  /// 播放停滞检测定时器。
  Timer? _playbackWatchdogTimer;

  /// 上一次检测到的播放位置。
  Duration? _lastPlaybackProgress;

  /// 连续判定为停滞的次数。
  int _playbackWatchdogStallCount = 0;

  /// 连续「没有新数据到达」的采样次数。
  ///
  /// 位置冻结要连续 6 次采样才判定，静默断流时太慢；累计流量是否增长是
  /// 与位置无关的独立信号，可在位置阈值之前触发恢复。
  int _playbackNoDataSampleCount = 0;

  /// 上一次采样到的累计读取字节数，null 表示上一次没拿到可比较的数值。
  int? _lastTotalBytes;

  /// 连续判定为「进度在推进」的采样次数。
  ///
  /// 只有累计到阈值才算真正恢复，避免刚打开播放就触发一次恢复回调。
  int _playbackHealthyStreak = 0;

  /// 是否正在加速追赶累积的直播延迟（滞回状态，跨采样保留）。
  ///
  /// 深度落在触发与停止水位之间时靠它保持原状态，速率才不会在阈值附近抖动。
  bool _isCatchingUp = false;

  /// 上一次重置看门狗的时间，用于宽限期判断。
  DateTime? _playbackWatchdogResetAt;

  /// 播放器操作串行队列。
  Future<void> _playerOperationQueue = Future<void>.value();

  /// 串行执行播放器操作。
  ///
  /// media_kit 的事件回调直接运行在 mpv 内部的处理流程上，若在回调里立刻
  /// 发送 jump/open/stop 等命令，会与 mpv 自身的结束清理流程交错，破坏
  /// mpv 的播放状态机（表现为 mp_play_files 断言崩溃）。因此统一排队，
  /// 并延迟到当前事件处理结束后再执行。
  Future<void> enqueuePlayerOperation(Future<void> Function() operation) {
    final result = _playerOperationQueue.then((_) async {
      await Future<void>.delayed(_playerOperationDelay);
      // 超时保护：mpv 可能因等待网络数据而不响应命令，避免单个操作阻塞整个队列
      await operation().timeout(
        _playerOperationTimeout,
        onTimeout: () {
          Log.w("播放器操作超时（${_playerOperationTimeout.inSeconds} 秒），跳过本次操作");
        },
      );
    });
    _playerOperationQueue = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        // 记录后继续执行后续排队操作，不吞掉异常信息
        Log.logPrint(error);
      },
    );
    return result;
  }

  /// 重置并启动播放停滞检测。
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
      // 采样现在是异步的（要读累计流量），不等待结果以免阻塞定时器
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
  /// 直播流在 CDN 挂起或断流时不会产生任何 mpv 事件（既无 EOF 也无 error），
  /// 画面会永久停在最后一帧；这里用「播放位置是否推进」来发现停滞。
  Future<void> _checkPlaybackProgress() async {
    final sample = await _readPlaybackSample();
    final previous = _lastPlaybackProgress;
    final advanced = previous == null || previous != sample.position;
    _lastPlaybackProgress = sample.position;
    // 上一次拿不到数值时无法比较，只能先当作有新数据，避免开局就误判断流
    final dataAdvanced =
        _lastTotalBytes == null || sample.totalBytes != _lastTotalBytes;
    _lastTotalBytes = sample.totalBytes;
    // 只有「正在播放却位置不变 / 没有新数据」的采样才算样本，其余情况立即清零
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
  /// 累计流量要异步读属性，因此读完后再取状态快照，避免判定用到过期状态。
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
        break;
    }
  }

  /// 记录一次「播放进度在推进」的采样。
  ///
  /// 只有连续达到阈值才视为真正恢复：否则每次 open 后的第一次采样就会
  /// 清空重试预算，让重试上限形同虚设。用 == 判断保证一次恢复只回调一次。
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
    // 无数据采样计数不清零的话，下一次采样（5 秒后）仍处于超阈值状态，会立刻
    // 重复判定停滞、重复触发恢复；累计流量同理，重新 open 后比较基准已经变了。
    _playbackNoDataSampleCount = 0;
    _lastTotalBytes = null;
    Log.w("播放停滞，尝试恢复");
    _writeStallDiagnose();
    mediaStalled();
  }

  /// 播放停滞回调，默认按播放错误处理，子类可覆盖。
  void mediaStalled() {
    mediaError("播放停滞");
  }

  /// 播放是否已恢复正常（子类据此清零重试预算、撤销误报状态）。
  void onPlaybackHealthy() {}

  /// 当前播放目标的描述，用于停滞现场取证（例如线路主机名）。
  String describePlaybackTarget() => "";

  /// mpv 累计流量属性名。
  static const String _totalBytesProperty = 'total-bytes';

  /// 读取 mpv 属性失败时写入的占位值。
  static const String _unknownPropertyValue = "unknown";

  /// 停滞时落盘现场证据。
  ///
  /// 这条通道不依赖「日志开关」设置：用户复现时往往没开日志，
  /// 没有现场数据就无法区分「数据没到」与「到了但没解码」。
  void _writeStallDiagnose() {
    final state = player.state;
    // 同步取出状态，异步部分只读属性与落盘，不阻塞看门狗定时器
    final content = "time=${DateTime.now()}"
        " position=${state.position.inMilliseconds}ms"
        " buffering=${state.buffering}"
        " playing=${state.playing}"
        " completed=${state.completed}"
        " buffer=${state.buffer.inMilliseconds}ms"
        " target=${describePlaybackTarget()}";
    unawaited(_appendStallDiagnose(content));
  }

  /// 读取累计流量后追加落盘（getProperty 是异步的）。
  Future<void> _appendStallDiagnose(String content) async {
    final totalBytes = await _readPlayerProperty(_totalBytesProperty);
    Log.writeDiagnose("$content total-bytes=$totalBytes");
  }

  /// 读取 mpv 属性并转为字符串，失败时返回 unknown。
  Future<String> _readPlayerProperty(String property) async {
    try {
      final platform = player.platform;
      // getProperty 只由 NativePlayer 提供，Web 端等实现没有这个能力
      if (platform is! NativePlayer) {
        return _unknownPropertyValue;
      }
      return await platform.getProperty(property);
    } catch (e) {
      Log.logPrint(e);
      return _unknownPropertyValue;
    }
  }

  StreamSubscription? _completedSubscription;
  StreamSubscription? _widthSubscription;
  StreamSubscription? _heightSubscription;
  StreamSubscription? _logSubscription;
  StreamSubscription? _playingSubscription;

  void initStream() {
    _errorSubscription = player.stream.error.listen((event) {
      Log.d("播放器错误：$event");
      // 跳过无音频输出的错误
      // Could not open/initialize audio device -> no sound.
      if (event.contains('no sound.')) {
        return;
      }
      //SmartDialog.showToast(event);
      mediaError(event);
    });

    _playingSubscription = player.stream.playing.listen((event) {
      if (event) {
        WakelockPlus.enable();
        Log.d("Playing");
      }
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
      Log.d(
        'width:$event  W:${(player.state.width)}  H:${(player.state.height)}',
      );
      isVertical.value =
          (player.state.height ?? 9) > (player.state.width ?? 16);
    });
    _heightSubscription = player.stream.height.listen((event) {
      Log.d(
        'height:$event  W:${(player.state.width)}  H:${(player.state.height)}',
      );
      isVertical.value =
          (player.state.height ?? 9) > (player.state.width ?? 16);
    });
  }

  void disposeStream() {
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _widthSubscription?.cancel();
    _heightSubscription?.cancel();
    _logSubscription?.cancel();
    _pipSubscription?.cancel();
    _playingSubscription?.cancel();
  }

  void mediaEnd() {
    WakelockPlus.disable();
  }

  void mediaError(String error) {
    WakelockPlus.disable();
  }

  void showDebugInfo() {
    Utils.showBottomSheet(
      title: "播放信息",
      child: ListView(
        children: [
          ListTile(
            title: const Text("Resolution"),
            subtitle: Text('${player.state.width}x${player.state.height}'),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text:
                      "Resolution\n${player.state.width}x${player.state.height}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("VideoParams"),
            subtitle: Text(player.state.videoParams.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(text: "VideoParams\n${player.state.videoParams}"),
              );
            },
          ),
          ListTile(
            title: const Text("AudioParams"),
            subtitle: Text(player.state.audioParams.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(text: "AudioParams\n${player.state.audioParams}"),
              );
            },
          ),
          ListTile(
            title: const Text("Media"),
            subtitle: Text(player.state.playlist.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(text: "Media\n${player.state.playlist}"),
              );
            },
          ),
          ListTile(
            title: const Text("AudioTrack"),
            subtitle: Text(player.state.track.audio.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(text: "AudioTrack\n${player.state.track.audio}"),
              );
            },
          ),
          ListTile(
            title: const Text("VideoTrack"),
            subtitle: Text(player.state.track.video.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(text: "VideoTrack\n${player.state.track.audio}"),
              );
            },
          ),
          ListTile(
            title: const Text("AudioBitrate"),
            subtitle: Text(player.state.audioBitrate.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "AudioBitrate\n${player.state.audioBitrate}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("Volume"),
            subtitle: Text(player.state.volume.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(text: "Volume\n${player.state.volume}"),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  void onClose() async {
    Log.w("播放器关闭");
    stopPlaybackWatchdog();
    if (smallWindowState.value) {
      exitSmallWindow();
    }
    disposeStream();
    disposeDanmakuController();
    await resetSystem();
    // 先停止播放，再延迟销毁：避免 mpv 事件回调仍在执行时关闭 Dart 回调
    unawaited(
      enqueuePlayerOperation(() async {
        await player.stop();
        await Future<void>.delayed(_playerDisposeDelay);
        await player.dispose();
      }),
    );
    super.onClose();
  }
}
