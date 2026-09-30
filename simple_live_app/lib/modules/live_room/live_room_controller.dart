import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// 直接依赖 window_manager：本控制器需自行订阅窗口事件，不依赖 PlayerController 的传递导入
import 'package:window_manager/window_manager.dart';

class LiveRoomController extends PlayerController
    with WidgetsBindingObserver, WindowListener {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
    // 抖音应该默认是竖屏的
    if (site.id == "douyin") {
      isVertical.value = true;
    }
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;
  RxList<LiveSuperChatMessage> superChats = RxList<LiveSuperChatMessage>();

  /// 滚动控制
  final ScrollController scrollController = ScrollController();

  /// 聊天信息
  RxList<LiveMessage> messages = RxList<LiveMessage>();

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 是否显示右侧信息面板
  RxBool showInfoPanel = true.obs;

  /// 退出倒计时
  var countdown = 60.obs;

  Timer? autoExitTimer;

  /// 设置的自动关闭时间（分钟）
  var autoExitMinutes = 60.obs;

  ///是否延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  /// 是否禁用自动滚动聊天栏
  /// - 当用户向上滚动聊天栏时，不再自动滚动
  var disableAutoScroll = false.obs;

  /// 是否处于后台
  var isBackground = false;

  /// 直播间加载失败
  var loadError = false.obs;
  Error? error;

  // 开播时长状态变量
  var liveDuration = "00:00:00".obs;
  Timer? _liveDurationTimer;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    // 订阅窗口真实全屏事件：窗口状态可能被系统/用户改变，只有事件才是权威来源
    windowManager.addListener(this);
    if (FollowService.instance.followList.isEmpty) {
      FollowService.instance.loadData();
    }
    initAutoExit();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    loadData();

    scrollController.addListener(scrollListener);

    super.onInit();
  }

  void scrollListener() {
    if (scrollController.position.userScrollDirection ==
        ScrollDirection.forward) {
      disableAutoScroll.value = true;
    }
  }

  /// 初始化自动关闭倒计时
  void initAutoExit() {
    if (AppSettingsController.instance.autoExitEnable.value) {
      autoExitEnable.value = true;
      autoExitMinutes.value =
          AppSettingsController.instance.autoExitDuration.value;
      setAutoExit();
    } else {
      autoExitMinutes.value =
          AppSettingsController.instance.roomAutoExitDuration.value;
    }
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      autoExitTimer?.cancel();
      return;
    }
    autoExitTimer?.cancel();
    countdown.value = autoExitMinutes.value * 60;
    autoExitTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      countdown.value -= 1;
      if (countdown.value <= 0) {
        timer = Timer(const Duration(seconds: 10), () async {
          await WakelockPlus.disable();
          exit(0);
        });
        autoExitTimer?.cancel();
        var delay = await Utils.showAlertDialog("定时关闭已到时,是否延迟关闭?",
            title: "延迟关闭", confirm: "延迟", cancel: "关闭", selectable: true);
        if (delay) {
          timer.cancel();
          delayAutoExit.value = true;
          showAutoExitSheet();
          setAutoExit();
        } else {
          delayAutoExit.value = false;
          await WakelockPlus.disable();
          exit(0);
        }
      }
    });
  }
  // 弹窗逻辑

  void refreshRoom() {
    //messages.clear();
    superChats.clear();
    liveDanmaku.stop();

    loadData();
  }

  /// 聊天栏始终滚动到底部
  void chatScrollToBottom() {
    if (scrollController.hasClients) {
      // 如果手动上拉过，就不自动滚动到底部
      if (disableAutoScroll.value) {
        return;
      }
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    }
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      if (messages.length > 200 && !disableAutoScroll.value) {
        messages.removeAt(0);
      }

      // 关键词屏蔽检查
      for (var keyword in AppSettingsController.instance.shieldList) {
        Pattern? pattern;
        if (Utils.isRegexFormat(keyword)) {
          String removedSlash = Utils.removeRegexFormat(keyword);
          try {
            pattern = RegExp(removedSlash);
          } catch (e) {
            // should avoid this during add keyword
            Log.d("关键词：$keyword 正则格式错误");
          }
        } else {
          pattern = keyword;
        }
        if (pattern != null && msg.message.contains(pattern)) {
          Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
          return;
        }
      }

      messages.add(msg);

      WidgetsBinding.instance.addPostFrameCallback(
        (_) => chatScrollToBottom(),
      );
      if (!liveStatus.value || isBackground) {
        return;
      }

      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: Color.fromARGB(
            255,
            msg.color.r,
            msg.color.g,
            msg.color.b,
          ),
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      superChats.add(msg.data);
    }
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    messages.add(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "LiveSysMessage",
        message: msg,
        color: LiveMessageColor.white,
      ),
    );
  }

  /// 接收到WebSocket关闭信息
  void onWSClose(String msg) {
    addSysMsg(msg);
  }

  /// WebSocket准备就绪
  void onWSReady() {
    addSysMsg("弹幕服务器连接正常");
  }

  /// 加载直播间信息
  void loadData() async {
    try {
      SmartDialog.showLoading(msg: "");
      loadError.value = false;
      error = null;
      update();
      addSysMsg("正在读取直播间信息");
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);
      // 取流签名有时效，记录获取时刻供申请地址前判断新鲜度
      _streamSignatureFetchedAt = DateTime.now();

      if (site.id == Constant.kDouyin) {
        // 1.6.0之前收藏的WebRid
        // 1.6.0收藏的RoomID
        // 1.6.0之后改回WebRid
        if (detail.value!.roomId != roomId) {
          var oldId = roomId;
          rxRoomId.value = detail.value!.roomId;
          if (followed.value) {
            // 更新关注列表
            DBService.instance.deleteFollow("${site.id}_$oldId");
            DBService.instance.addFollow(
              FollowUser(
                id: "${site.id}_$roomId",
                roomId: roomId,
                siteId: site.id,
                userName: detail.value!.userName,
                face: detail.value!.userAvatar,
                addTime: DateTime.now(),
              ),
            );
          } else {
            followed.value =
                DBService.instance.getFollowExist("${site.id}_$roomId");
          }
        }
      }

      getSuperChatMessage();

      addHistory();
      // 确认房间关注状态
      followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        addSysMsg("当前主播未开播，正在轮播录像");
      }
      addSysMsg("开始连接弹幕服务器");
      initDanmau();
      liveDanmaku.start(detail.value?.danmakuData);
      startLiveDurationTimer(); // 启动开播时长定时器
    } catch (e) {
      Log.logPrint(e);
      //SmartDialog.showToast(e.toString());
      loadError.value = true;
      error = e as Error;
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 初始化播放器
  void getPlayQualites() async {
    qualites.clear();
    currentQuality = -1;

    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: detail.value!);

      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = await getQualityLevel();
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      getPlayUrl();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放清晰度");
    }
  }

  Future<int> getQualityLevel() async {
    var qualityLevel = AppSettingsController.instance.qualityLevel.value;
    try {
      var connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.first == ConnectivityResult.mobile) {
        qualityLevel =
            AppSettingsController.instance.qualityLevelCellular.value;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return qualityLevel;
  }

  /// 获取播放地址并开始播放。
  ///
  /// [resetLine] 为 true 时回到第一条线路，并重置重试次数（用户主动
  /// 重新开始播放）；为 false 时保持当前线路与重试次数（自动重连）。
  void getPlayUrl({bool resetLine = true}) async {
    // 页面已关闭时不能再发起站点请求（后续还有 toast 与播放器操作，都已无对象）
    if (isClosed) return;
    // 清晰度数据缺失时不能访问下标，改为记录并安排重试
    if (qualites.isEmpty ||
        currentQuality < 0 ||
        currentQuality >= qualites.length) {
      Log.w("清晰度数据不可用，无法读取播放地址");
      SmartDialog.showToast("无法读取播放地址");
      await _onPlayUrlFailure();
      schedulePlaybackRecover("清晰度数据不可用");
      return;
    }
    // 不在开头清空 playUrls：清空会让 recoverPlayback 的「还有下一条线路吗」判断失真
    currentQualityInfo.value = qualites[currentQuality].quality;
    currentLineInfo.value = "";
    if (resetLine) {
      currentLineIndex = 0;
      //重置错误次数
      mediaErrorRetryCount = 0;
      // 用户切清晰度/换线路重来时应当重新获得完整重试预算，否则预算耗尽后自动恢复不再生效
      _recoverRetryCount = 0;
    }
    // 取流签名会失效，且失效时连刷新地址本身都会失败（error -9）：先刷新签名再申请地址
    await _ensureFreshStreamSignature();
    try {
      var playUrl = await site.liveSite.getPlayUrls(
        detail: detail.value!,
        quality: qualites[currentQuality],
      );
      if (playUrl.urls.isEmpty) {
        SmartDialog.showToast("无法读取播放地址");
        // 申请地址失败时安排重试，避免自动恢复链中断
        await _onPlayUrlFailure();
        schedulePlaybackRecover("获取播放地址失败");
        return;
      }
      // 整体替换地址列表，保证中途失败时旧线路信息仍然可用
      playUrls.value = playUrl.urls;
      playHeaders = playUrl.headers;
      _playUrlFailureCount = 0;
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放地址");
      await _onPlayUrlFailure();
      schedulePlaybackRecover("获取播放地址异常");
      return;
    }
    // 地址列表变化后线路越界时回到第一条
    if (currentLineIndex < 0 || currentLineIndex >= playUrls.length) {
      currentLineIndex = 0;
    }
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    initPlaylist();
  }

  /// 切换播放线路。
  ///
  /// 直播地址会随时间失效，因此切换线路同样重新申请地址，而不是重放
  /// 之前拿到的旧地址。
  ///
  /// [userInitiated] 为 true 表示用户手动换线路：此时补满重试预算，否则预算用尽后
  /// 用户手动换线路也救不回来；自动恢复链内部的换线路必须保持默认值，不能绕过上限。
  void changePlayLine(int index, {bool userInitiated = false}) {
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    if (userInitiated) {
      _recoverRetryCount = 0;
    }
    getPlayUrl(resetLine: false);
  }

  void initPlaylist() async {
    // 控制器已销毁时不再动播放器
    if (isClosed) return;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    if (playUrls.isEmpty) {
      return;
    }

    final mediaList = playUrls.map((url) {
      var finalUrl = url;
      if (AppSettingsController.instance.playerForceHttps.value) {
        finalUrl = finalUrl.replaceAll("http://", "https://");
      }
      return Media(finalUrl, httpHeaders: playHeaders);
    }).toList();

    // 先启动看门狗：即使 open 抛异常，恢复链仍在运行（该方法幂等）
    startPlaybackWatchdog();

    try {
      // 初始化播放器并设置 ao 参数
      await initializePlayer();

      // 从当前线路开始播放，重连时保持原线路
      await player.open(
        Playlist(
          mediaList,
          index: currentLineIndex.clamp(0, mediaList.length - 1),
        ),
      );
    } catch (e) {
      Log.logPrint(e);
      schedulePlaybackRecover("打开播放失败");
      return;
    }
    // 地址带 expire 时提前刷新，避免到期被 CDN 断开
    schedulePlayUrlRefresh();
  }

  @override
  void mediaEnd() {
    super.mediaEnd();
    enqueuePlayerOperation(() async {
      recoverPlayback("播放结束");
    });
  }

  @override
  void mediaError(String error) {
    super.mediaError(error);
    enqueuePlayerOperation(() async {
      recoverPlayback("播放失败：$error");
    });
  }

  @override
  void mediaStalled() {
    enqueuePlayerOperation(() async {
      recoverPlayback("播放停滞");
    });
  }

  /// 播放异常后的恢复流程。
  ///
  /// 每条线路分两级：先原地重建（复用缓存的地址，不发站点请求），原地重建无效才
  /// 重新向站点申请地址；当前线路连续失败后再切换到下一条线路。
  ///
  /// 之所以把重新申请地址放到第二级：断流多为连接层问题，原地重建代价更小；且
  /// 高频申请地址会被风控，一旦被风控连正确签名的地址都拿不到，恢复链反而彻底失效。
  void recoverPlayback(String reason) {
    // 页面已关闭：入队的恢复操作可能在销毁后才跑到，不能再发起请求与弹提示
    if (isClosed) return;
    // 断流时 mpv 每秒会吐出 5-12 条错误，每条都走到这里：不冷却就等于「错误频率
    // 即请求频率」，几秒内几十次站点请求会触发风控（取流接口开始返回 -9），本来
    // 等下一次重试就能恢复的播放反而彻底恢复不了。
    final lastRecoverAt = _lastRecoverAt;
    if (lastRecoverAt != null &&
        DateTime.now().difference(lastRecoverAt) < _recoverCooldown) {
      Log.d("$reason，距上次恢复不足 ${_recoverCooldown.inSeconds} 秒，跳过本次恢复");
      return;
    }
    _lastRecoverAt = DateTime.now();
    // 已有待触发的退避重试时，恢复节奏交给定时器：否则 error 风暴会借这条快路径
    // 每 5 秒（冷却窗口）再发一轮取流请求，仍然足以触发风控。
    final pendingRetry = _playbackRecoverTimer;
    if (pendingRetry != null && pendingRetry.isActive) {
      Log.d("$reason，已有待触发的重试，交由退避定时器恢复");
      return;
    }
    // 能走到这里说明此前确实播放过，即使当前标记为未开播也尝试恢复
    // （直播流断开与主播下播无法仅凭播放状态区分，交由后续确认流程处理）
    if (mediaErrorRetryCount < _maxRetryPerLine) {
      mediaErrorRetryCount += 1;
      // 直播断流多为连接层问题（CDN 抖动、TCP 断开），缓存地址往往仍然有效：原地
      // 重建就能恢复且会从最新位置续播，代价只是一次播放器重开，不发站点请求；
      // 高频申请地址会被风控，连正确签名的地址都拿不到，恢复链反而彻底失效。
      if (mediaErrorRetryCount == 1 && playUrls.isNotEmpty) {
        Log.w("$reason，第$mediaErrorRetryCount 次原地重新打开播放器");
        initPlaylist();
        return;
      }
      Log.w("$reason，第$mediaErrorRetryCount 次重新获取播放地址");
      getPlayUrl(resetLine: false);
      return;
    }
    mediaErrorRetryCount = 0;
    if (currentLineIndex + 1 < playUrls.length) {
      Log.w("$reason，切换到线路${currentLineIndex + 2}");
      changePlayLine(currentLineIndex + 1);
      return;
    }
    Log.w("$reason，所有线路均无法播放");
    errorMsg.value = "播放失败";
    unawaited(confirmLiveStatusAndRetry(reason));
  }

  /// 两次恢复尝试之间的最小间隔。
  ///
  /// 断流时 mpv 每秒产生 5-12 条错误，每条错误都会触发一次完整恢复：不冷却就等于
  /// 「错误频率即请求频率」，几秒内几十次站点请求会触发风控（取流接口返回 -9
  /// 时间戳错误），反而让本来能恢复的播放彻底恢复不了。
  static const Duration _recoverCooldown = Duration(seconds: 5);

  /// 上一次真正发起恢复尝试的时刻，null 表示还没恢复过或已恢复健康。
  DateTime? _lastRecoverAt;

  /// 播放全部失败后确认房间真实状态。
  ///
  /// 直播流断开（CDN 切换、网络抖动、地址过期）与主播下播都会让播放
  /// 结束，仅凭播放失败无法区分；这里向站点确认，主播仍在直播时继续
  /// 重试，避免误报「未开播」。接口确认失败不等于下播：网络异常同样会
  /// 抛错，此时仍按「正在重试」处理，只有明确返回 status=false 且不是录播，
  /// 才认定主播已下播。
  ///
  /// 录播房间的 status 为 false、isRecord 为 true，但仍提供可播放的流，只看
  /// status 会把仍在播放的轮播录像误判成主播已下播，因此与 loadData 的判定
  /// 保持一致，把 isRecord 也算作可继续重试的状态。
  Future<void> confirmLiveStatusAndRetry(String reason) async {
    try {
      var roomDetail = await site.liveSite.getRoomDetail(roomId: roomId);
      if (roomDetail.status || roomDetail.isRecord) {
        Log.w("$reason，确认主播仍在直播，继续重试");
        errorMsg.value = "播放中断，正在重试";
        _armRecoverTimer(reason);
        return;
      }
    } catch (e) {
      // 确认失败不等于下播：继续重试，避免把网络异常误报成直播结束
      Log.logPrint(e);
      errorMsg.value = "播放中断，正在重试";
      _armRecoverTimer("房间状态确认失败：$reason");
      return;
    }
    Log.w("$reason，主播已下播");
    liveStatus.value = false;
    SmartDialog.showToast("直播已结束");
  }

  /// 恢复重试的间隔序列（秒）。
  ///
  /// 站点对高频请求会触发风控（返回异常数据结构），逐次拉长间隔以降低风险。
  static const List<int> _recoverRetrySeconds = [20, 30, 45, 60, 90, 120];

  /// 当前适用的恢复重试间隔。
  Duration get _recoverRetryInterval {
    final index = _recoverRetryCount.clamp(0, _recoverRetrySeconds.length - 1);
    return Duration(seconds: _recoverRetrySeconds[index]);
  }

  /// 播放全部失败后的重试定时器。
  Timer? _playbackRecoverTimer;

  /// 播放地址刷新定时器。
  ///
  /// 斗鱼等平台的播放地址带 expire（常见 300 秒），到期后 CDN 会主动断开
  /// 连接，表现为「播放一会就不动了」；提前刷新可避免这种中断。
  Timer? _playUrlRefreshTimer;

  /// 提前刷新播放地址的余量（秒）。
  static const int _playUrlRefreshLeadSeconds = 45;

  /// 解析当前线路播放地址的剩余有效期，并安排在过期前主动刷新。
  void schedulePlayUrlRefresh() {
    _playUrlRefreshTimer?.cancel();
    if (playUrls.isEmpty) {
      return;
    }
    final hasCurrentLine =
        currentLineIndex >= 0 && currentLineIndex < playUrls.length;
    // 实际播放的是当前线路，按下标取地址；下标越界时才退回首条（原有兜底）
    final currentUrl =
        hasCurrentLine ? playUrls[currentLineIndex] : playUrls.first;
    final expireSeconds = parsePlayUrlExpireSeconds(currentUrl);
    if (expireSeconds == null ||
        expireSeconds <= _playUrlRefreshLeadSeconds * 2) {
      return;
    }
    final refreshSeconds = expireSeconds - _playUrlRefreshLeadSeconds;
    Log.d("播放地址有效期 $expireSeconds 秒，将在 $refreshSeconds 秒后主动刷新");
    _playUrlRefreshTimer = Timer(Duration(seconds: refreshSeconds), () {
      Log.d("播放地址即将过期，主动刷新");
      mediaErrorRetryCount = 0;
      getPlayUrl(resetLine: false);
    });
  }

  /// 取流签名的保鲜时长。
  ///
  /// 房间详情里的时间戳签名实测在获取后 8~13 分钟内失效（真机日志里 8 分 37 秒
  /// 还能刷新地址，12 分 52 秒已返回 error -9）；取 5 分钟既留足余量，又让刷新频率
  /// （每 5 分钟一次）低到不会触发站点风控。
  static const Duration _streamSignatureLifetime = Duration(minutes: 5);

  /// 上一次获取取流签名的时刻，用于判断签名是否还新鲜；null 表示尚未记录过。
  DateTime? _streamSignatureFetchedAt;

  /// 申请地址前确保取流签名足够新。
  ///
  /// 站点的取流参数带时间戳签名，实测 8~13 分钟后服务端开始返回
  /// 「时间戳错误（error -9）」；此时连主动刷新地址都会失败，只能等恢复链重试，
  /// 一次就是几十秒中断。因此在申请地址之前主动刷新，而不是等失败后再补。
  Future<void> _ensureFreshStreamSignature() async {
    final fetchedAt = _streamSignatureFetchedAt;
    if (fetchedAt == null ||
        DateTime.now().difference(fetchedAt) < _streamSignatureLifetime) {
      return;
    }
    try {
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);
      _streamSignatureFetchedAt = DateTime.now();
      Log.d("取流签名已超过 ${_streamSignatureLifetime.inMinutes} 分钟，已重新获取房间详情");
    } catch (e) {
      // 刷新失败不能阻塞取流：旧签名可能仍然可用，真的失效由恢复链兜底
      Log.logPrint(e);
    }
  }

  /// 连续确认主播在播但仍无法播放的最大重试次数。
  ///
  /// 间隔逐次拉长到 2 分钟，30 次重试最坏约 54 分钟（远超前述的 10 分钟）。
  static const int _recoverRetryLimit = 30;

  /// 已连续重试恢复播放的次数。
  int _recoverRetryCount = 0;

  /// 重试预算耗尽后的保活重试间隔。
  ///
  /// 长时间挂机（TV/桌面端）时用户不在场：彻底停止自动重连会让「主播仍在播、
  /// 网络稍后恢复」的画面永久停在失败状态，因此保留一条极低频的自愈路径。
  /// 间隔必须远大于退避上限：请求量低到不会再触发站点风控，又能等到网络恢复。
  static const Duration _recoverKeepAliveInterval = Duration(minutes: 5);

  /// 安排稍后重新尝试恢复播放。
  ///
  /// 用于获取播放地址失败等场景：此时不能直接中断恢复链，需要留下后续重试。
  void schedulePlaybackRecover(String reason) {
    _armRecoverTimer(reason);
  }

  /// 取地址连续失败多少次后重新拉取房间详情。
  ///
  /// 斗鱼的取流参数（args）里带生成时刻的签名，复用十几分钟后接口会返回
  /// error -9「时间戳错误」，此后每次取地址都失败；重新拉取房间详情即重新签名。
  /// 不做这件事时，恢复链只会在旧签名上反复失败，直到重试上限。
  static const int _detailRefreshFailureThreshold = 2;

  /// 取地址连续失败的次数，取到地址后清零。
  int _playUrlFailureCount = 0;

  /// 两次刷新房间详情之间的最小间隔。
  ///
  /// 断流期间取地址失败每秒都可能发生，不限制就会变成每秒多次详情请求；被风控后
  /// 连签名都刷新不了，恢复链就再也没有可用的取流参数。
  static const Duration _detailRefreshCooldown = Duration(seconds: 30);

  /// 上一次刷新房间详情的时刻，null 表示本次会话还没刷新过。
  DateTime? _lastDetailRefreshAt;

  /// 取地址失败后的处理：达到阈值先刷新房间详情（刷新取流签名）。
  Future<void> _onPlayUrlFailure() async {
    _playUrlFailureCount += 1;
    if (_playUrlFailureCount < _detailRefreshFailureThreshold) {
      return;
    }
    final lastRefreshAt = _lastDetailRefreshAt;
    if (lastRefreshAt != null &&
        DateTime.now().difference(lastRefreshAt) < _detailRefreshCooldown) {
      Log.d("取地址连续失败，距上次刷新房间详情不足 "
          "${_detailRefreshCooldown.inSeconds} 秒，跳过本次刷新");
      return;
    }
    _playUrlFailureCount = 0;
    _lastDetailRefreshAt = DateTime.now();
    try {
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);
      // 重新获取详情即重新签名，同步更新新鲜度时刻
      _streamSignatureFetchedAt = DateTime.now();
      Log.w("取地址连续失败，已重新获取房间详情（刷新取流签名）");
    } catch (e) {
      // 刷新失败不影响后续重试，仅记录
      Log.logPrint(e);
    }
  }

  /// 统一的重试入口。
  ///
  /// 取地址失败、打开失败、停滞恢复等所有自动恢复路径都必须经过这里：
  /// 若各路径各自启动定时器，重试预算上限就会被绕过，导致无限重试。
  void _armRecoverTimer(String reason) {
    if (isClosed) {
      return;
    }
    // 错误风暴期间每秒都会走到这里：若把已排定的定时器取消重建，退避出的长间隔
    // 永远等不到触发（活锁），退避反而变成「永不重试」；已有待触发的重试时放过。
    final pendingTimer = _playbackRecoverTimer;
    if (pendingTimer != null && pendingTimer.isActive) {
      Log.d("$reason，已有待触发的重试，忽略本次重置");
      return;
    }
    if (_recoverRetryCount >= _recoverRetryLimit) {
      Log.w("$reason，重试次数已达上限，转为每 "
          "${_recoverKeepAliveInterval.inMinutes} 分钟一次的保活重试");
      errorMsg.value = "播放失败，正在低频重试";
      // 保活重试不消耗也不重置预算：计数只能由画面恢复或用户主动操作清零
      _playbackRecoverTimer = Timer(_recoverKeepAliveInterval, () {
        Log.d("保活重试，重新获取播放地址（$reason）");
        mediaErrorRetryCount = 0;
        getPlayUrl(resetLine: false);
      });
      return;
    }
    _recoverRetryCount += 1;
    Log.w("$reason，${_recoverRetryInterval.inSeconds} 秒后重试恢复播放");
    _playbackRecoverTimer?.cancel();
    _playbackRecoverTimer = Timer(_recoverRetryInterval, () {
      Log.d("重新尝试恢复播放（$reason）");
      mediaErrorRetryCount = 0;
      getPlayUrl(resetLine: false);
    });
  }

  /// 每条线路的最大重试次数。
  static const int _maxRetryPerLine = 2;

  /// 记录的错误重试次数，播放恢复正常后清零。
  int mediaErrorRetryCount = 0;

  @override
  void onPlaybackHealthy() {
    // 连续约 15 秒（看门狗 3 次采样）播放进度都在推进才回调到这里：说明主播仍在
    // 直播，可以撤销误报的「未开播」并清零重试预算。单次推进不足以清零，否则
    // 5 秒级的播放抖动会让 30 次重试上限失效。
    // 不能依赖 player.stream.playing：media_kit 的事件流是 distinct 的，
    // 断流恢复时 playing 值往往没有变化，事件不会重发。
    if (!liveStatus.value) {
      liveStatus.value = true;
    }
    final clearedRetries = _recoverRetryCount;
    mediaErrorRetryCount = 0;
    _recoverRetryCount = 0;
    _playbackRecoverTimer?.cancel();
    // 恢复健康后允许立即响应下一次真实断流，否则会在冷却窗口里被静默丢弃
    _lastRecoverAt = null;
    // 恢复成功没有别的可见信号，事后排查断流只能靠这条日志确认「确实自愈了」
    Log.w("画面恢复，重试预算已清零（本次重试 $clearedRetries 次）");
  }

  @override
  String describePlaybackTarget() {
    if (playUrls.isEmpty) return "无可用线路";
    final current = playUrls[currentLineIndex.clamp(0, playUrls.length - 1)];
    return Uri.tryParse(current)?.host ?? "未知线路";
  }

  /// 窗口模式下「顶部标题栏 + 底部操作栏」是否显示。
  ///
  /// 与播放器控件浮层（showControlsState）分开驱动：浮层隐藏时鼠标可能仍在画面里，
  /// 而页面框架隐藏会让画面变大、鼠标又落回画面区域，两者绑定会互相触发形成显隐抖动。
  final showPageChrome = true.obs;

  /// 页面框架自动隐藏前的空闲时间。
  static const Duration _pageChromeIdleDelay = Duration(seconds: 4);

  /// 页面框架的空闲隐藏定时器。
  Timer? _pageChromeTimer;

  /// 鼠标有动作：显示页面框架，并重新开始空闲计时。
  void revealPageChrome() {
    if (isClosed) {
      return;
    }
    if (!showPageChrome.value) {
      showPageChrome.value = true;
    }
    _pageChromeTimer?.cancel();
    _pageChromeTimer = Timer(_pageChromeIdleDelay, hidePageChrome);
  }

  /// 立即隐藏页面框架（鼠标移出窗口或空闲超时）。
  void hidePageChrome() {
    if (isClosed) {
      return;
    }
    _pageChromeTimer?.cancel();
    _pageChromeTimer = null;
    if (showPageChrome.value) {
      showPageChrome.value = false;
    }
  }

  /// 读取SC
  void getSuperChatMessage() async {
    try {
      var sc =
          await site.liveSite.getSuperChatMessage(roomId: detail.value!.roomId);
      superChats.addAll(sc);
    } catch (e) {
      Log.logPrint(e);
      addSysMsg("SC读取失败");
    }
  }

  /// 移除掉已到期的SC
  void removeSuperChats() async {
    var now = DateTime.now().millisecondsSinceEpoch;
    superChats.value = superChats
        .where((x) => x.endTime.millisecondsSinceEpoch > now)
        .toList();
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  void followUser() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    DBService.instance.addFollow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
      return;
    }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  void share() {
    if (detail.value == null) {
      return;
    }
    SharePlus.instance.share(ShareParams(uri: Uri.parse(detail.value!.url)));
  }

  void copyUrl() {
    if (detail.value == null) {
      return;
    }
    Utils.copyToClipboard(detail.value!.url);
    SmartDialog.showToast("已复制直播间链接");
  }

  /// 复制新生成的直播流
  void copyPlayUrl() async {
    // 未开播不复制
    if (!liveStatus.value) {
      return;
    }
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    Utils.copyToClipboard(playUrl.urls.first);
    SmartDialog.showToast("已复制播放直链");
  }

  /// 底部打开播放器设置
  void showDanmuSettingsSheet() {
    Utils.showBottomSheet(
      title: "弹幕设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            onTapDanmuShield: () {
              Get.back();
              showDanmuShield();
            },
          ),
        ],
      ),
    );
  }

  void showVolumeSlider(BuildContext targetContext) {
    SmartDialog.showAttach(
      targetContext: targetContext,
      alignment: Alignment.topCenter,
      displayTime: const Duration(seconds: 3),
      maskColor: const Color(0x00000000),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: AppStyle.radius12,
            color: Theme.of(context).cardColor,
          ),
          padding: AppStyle.edgeInsetsA4,
          child: Obx(
            () => SizedBox(
              width: 200,
              child: Slider(
                min: 0,
                max: 100,
                value: AppSettingsController.instance.playerVolume.value,
                onChanged: (newValue) {
                  player.setVolume(newValue);
                  AppSettingsController.instance.setPlayerVolume(newValue);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void showQualitySheet() {
    Utils.showBottomSheet(
      title: "切换清晰度",
      child: RadioGroup(
        groupValue: currentQuality,
        onChanged: (e) {
          Get.back();
          currentQuality = e ?? 0;
          getPlayUrl();
        },
        child: ListView.builder(
          itemCount: qualites.length,
          itemBuilder: (_, i) {
            var item = qualites[i];
            return RadioListTile(
              value: i,
              title: Text(item.quality),
            );
          },
        ),
      ),
    );
  }

  void showPlayUrlsSheet() {
    Utils.showBottomSheet(
      title: "切换线路",
      child: RadioGroup(
        groupValue: currentLineIndex,
        onChanged: (e) {
          Get.back();
          //currentLineIndex = i;
          //setPlayer();
          changePlayLine(e ?? 0, userInitiated: true);
        },
        child: ListView.builder(
          itemCount: playUrls.length,
          itemBuilder: (_, i) {
            return RadioListTile(
              value: i,
              title: Text("线路${i + 1}"),
              secondary: Text(
                playUrls[i].contains(".flv") ? "FLV" : "HLS",
              ),
            );
          },
        ),
      ),
    );
  }

  void showPlayerSettingsSheet() {
    Utils.showBottomSheet(
      title: "画面尺寸",
      child: Obx(
        () => RadioGroup(
          groupValue: AppSettingsController.instance.scaleMode.value,
          onChanged: (e) {
            AppSettingsController.instance.setScaleMode(e ?? 0);
            updateScaleMode();
          },
          child: ListView(
            padding: AppStyle.edgeInsetsV12,
            children: const [
              RadioListTile(
                value: 0,
                title: Text("适应"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 1,
                title: Text("拉伸"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 2,
                title: Text("铺满"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 3,
                title: Text("16:9"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 4,
                title: Text("4:3"),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showDanmuShield() {
    TextEditingController keywordController = TextEditingController();

    void addKeyword() {
      if (keywordController.text.isEmpty) {
        SmartDialog.showToast("请输入关键词");
        return;
      }

      AppSettingsController.instance
          .addShieldList(keywordController.text.trim());
      keywordController.text = "";
    }

    Utils.showBottomSheet(
      title: "关键词屏蔽",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          TextField(
            controller: keywordController,
            decoration: InputDecoration(
              contentPadding: AppStyle.edgeInsetsH12,
              border: const OutlineInputBorder(),
              hintText: "请输入关键词",
              suffixIcon: TextButton.icon(
                onPressed: addKeyword,
                icon: const Icon(Icons.add),
                label: const Text("添加"),
              ),
            ),
            onSubmitted: (e) {
              addKeyword();
            },
          ),
          AppStyle.vGap12,
          Obx(
            () => Text(
              "已添加${AppSettingsController.instance.shieldList.length}个关键词（点击移除）",
              style: Get.textTheme.titleSmall,
            ),
          ),
          AppStyle.vGap12,
          Obx(
            () => Wrap(
              runSpacing: 12,
              spacing: 12,
              children: AppSettingsController.instance.shieldList
                  .map(
                    (item) => InkWell(
                      borderRadius: AppStyle.radius24,
                      onTap: () {
                        AppSettingsController.instance.removeShieldList(item);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: AppStyle.radius24,
                        ),
                        padding: AppStyle.edgeInsetsH12.copyWith(
                          top: 4,
                          bottom: 4,
                        ),
                        child: Text(
                          item,
                          style: Get.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  void showFollowUserSheet() {
    Utils.showBottomSheet(
      title: "关注列表",
      child: Obx(
        () => Stack(
          children: [
            RefreshIndicator(
              onRefresh: FollowService.instance.loadData,
              child: ListView.builder(
                itemCount: FollowService.instance.liveList.length,
                itemBuilder: (_, i) {
                  var item = FollowService.instance.liveList[i];
                  return Obx(
                    () => FollowUserItem(
                      item: item,
                      playing: rxSite.value.id == item.siteId &&
                          rxRoomId.value == item.roomId,
                      onTap: () {
                        Get.back();
                        resetRoom(
                          Sites.allSites[item.siteId]!,
                          item.roomId,
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
              Positioned(
                right: 12,
                bottom: 12,
                child: Obx(
                  () => DesktopRefreshButton(
                    refreshing: FollowService.instance.updating.value,
                    onPressed: FollowService.instance.loadData,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void showAutoExitSheet() {
    if (AppSettingsController.instance.autoExitEnable.value &&
        !delayAutoExit.value) {
      SmartDialog.showToast("已设置了全局定时关闭");
      return;
    }
    Utils.showBottomSheet(
      title: "定时关闭",
      child: ListView(
        children: [
          Obx(
            () => SwitchListTile(
              title: Text(
                "启用定时关闭",
                style: Get.textTheme.titleMedium,
              ),
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;

                setAutoExit();
                //controller.setAutoExitEnable(e);
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                "自动关闭时间：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟",
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration =
                    Duration(hours: value.hour, minutes: value.minute);
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance
                    .setRoomAutoExitDuration(autoExitMinutes.value);
                //setAutoExitDuration(duration.inMinutes);
                setAutoExit();
              },
            ),
          ),
        ],
      ),
    );
  }

  void openNaviteAPP() async {
    var naviteUrl = "";
    var webUrl = "";
    if (site.id == Constant.kBiliBili) {
      naviteUrl = "bilibili://live/${detail.value?.roomId}";
      webUrl = "https://live.bilibili.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyin) {
      var args = detail.value?.danmakuData as DouyinDanmakuArgs;
      naviteUrl = "snssdk1128://webcast_room?room_id=${args.roomId}";
      webUrl = "https://live.douyin.com/${args.webRid}";
    } else if (site.id == Constant.kHuya) {
      var args = detail.value?.danmakuData as HuyaDanmakuArgs;
      naviteUrl =
          "yykiwi://homepage/index.html?banneraction=https%3A%2F%2Fdiy-front.cdn.huya.com%2Fzt%2Ffrontpage%2Fcc%2Fupdate.html%3Fhyaction%3Dlive%26channelid%3D${args.subSid}%26subid%3D${args.subSid}%26liveuid%3D${args.subSid}%26screentype%3D1%26sourcetype%3D0%26fromapp%3Dhuya_wap%252Fclick%252Fopen_app_guide%26&fromapp=huya_wap/click/open_app_guide";
      webUrl = "https://www.huya.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyu) {
      naviteUrl =
          "douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D${detail.value?.roomId}";
      webUrl = "https://www.douyu.com/${detail.value?.roomId}";
    }
    try {
      await launchUrlString(naviteUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开APP，将使用浏览器打开");
      await launchUrlString(webUrl, mode: LaunchMode.externalApplication);
    }
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    rxSite.value = site;
    rxRoomId.value = roomId;

    // 清除全部消息
    liveDanmaku.stop();
    messages.clear();
    superChats.clear();
    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();

    // 刷新信息
    loadData();
  }

  void copyErrorDetail() {
    Utils.copyToClipboard('''直播平台：${rxSite.value.name}
房间号：${rxRoomId.value}
错误信息：
${error?.toString()}
----------------
${error?.stackTrace}''');
    SmartDialog.showToast("已复制错误信息");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      isBackground = true;
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
    }
  }

  /// 窗口真实进入全屏时同步界面状态。
  ///
  /// 全屏可能由用户通过 macOS 绿灯、⌃⌘F 或 ESC 触发，app 无法预知；
  /// 只靠 enterFullScreen/exitFull 的乐观赋值会让界面状态与窗口真实状态分叉，
  /// 表现为无标题栏的全屏窗口里仍画着窗口模式的顶栏与底栏，被系统菜单栏遮挡。
  @override
  void onWindowEnterFullScreen() {
    fullScreenState.value = true;
  }

  /// 窗口真实退出全屏时同步界面状态（同上，以窗口事件为准）。
  @override
  void onWindowLeaveFullScreen() {
    fullScreenState.value = false;
  }

  // 用于启动开播时长计算和更新的函数
  void startLiveDurationTimer() {
    // 如果不是直播状态或者 showTime 为空，则不启动定时器
    if (!(detail.value?.status ?? false) || detail.value?.showTime == null) {
      liveDuration.value = "00:00:00"; // 未开播时显示 00:00:00
      _liveDurationTimer?.cancel();
      return;
    }

    try {
      int startTimeStamp = int.parse(detail.value!.showTime!);
      // 取消之前的定时器
      _liveDurationTimer?.cancel();
      // 创建新的定时器，每秒更新一次
      _liveDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        liveDuration.value = formattedDuration;
      });
    } catch (e) {
      liveDuration.value = "--:--:--"; // 错误时显示 --:--:--
    }
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    _pageChromeTimer?.cancel();
    _playbackRecoverTimer?.cancel();
    _playUrlRefreshTimer?.cancel();
    scrollController.removeListener(scrollListener);
    autoExitTimer?.cancel();

    liveDanmaku.stop();
    danmakuController = null;
    _liveDurationTimer?.cancel(); // 页面关闭时取消定时器
    super.onClose();
  }
}
