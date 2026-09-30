import 'dart:async';

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
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
  }
  final FocusNode focusNode = FocusNode();
  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;

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

  /// 是否处于后台
  var isBackground = false;

  var datetime = "00:00".obs;

  void initTimer() {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      var now = DateTime.now();
      datetime.value =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    });
  }

  /// 双击退出Flag
  bool doubleClickExit = false;

  /// 双击退出Timer
  Timer? doubleClickTimer;

  @override
  void onInit() {
    initTimer();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");

    loadData();

    super.onInit();
  }

  void refreshRoom() {
    //messages.clear();

    liveDanmaku.stop();

    loadData();
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
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

      if (!liveStatus.value || isBackground) {
        return;
      }

      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: Color.fromARGB(255, msg.color.r, msg.color.g, msg.color.b),
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      //superChats.add(msg.data);
    }
  }

  /// 加载直播间信息
  void loadData() async {
    try {
      SmartDialog.showLoading(msg: "");
      pageLoadding.value = true;
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);
      // 取流签名有时效，记录获取时刻供申请地址前判断新鲜度
      _streamSignatureFetchedAt = DateTime.now();

      addHistory();
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        SmartDialog.showToast("当前主播未开播，正在轮播录像");
      }

      initDanmau();
      liveDanmaku.start(detail.value?.danmakuData);
    } catch (e) {
      SmartDialog.showToast(e.toString());
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
      pageLoadding.value = false;
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
      var qualityLevel = AppSettingsController.instance.qualityLevel.value;
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

  /// 获取播放地址并开始播放。
  ///
  /// [resetLine] 为 true 时回到第一条线路并重置重试次数（用户主动重新开始
  /// 播放）；为 false 时保持当前线路与计数（自动重连，地址过期必须重新申请）。
  void getPlayUrl({bool resetLine = true}) async {
    // 页面已销毁：后续的请求、提示与播放器操作都已无对象
    if (isClosed) {
      return;
    }
    final roomDetail = detail.value;
    // 清晰度下标越界或房间信息缺失都会直接抛错，改为安排后续重试
    final hasQuality = currentQuality >= 0 && currentQuality < qualites.length;
    if (!hasQuality || roomDetail == null) {
      Log.w("清晰度或房间信息不可用，无法读取播放地址");
      schedulePlaybackRecover("播放信息不可用");
      return;
    }
    // 不在开头清空 playUrls：清空会让「还有下一条线路吗」的判断失真
    currentQualityInfo.value = qualites[currentQuality].quality;
    currentLineInfo.value = "";
    if (resetLine) {
      currentLineIndex = 0;
      //用户主动重新开始播放，重试次数归零
      mediaErrorRetryCount = 0;
    }
    // 取流签名会失效，且失效时连刷新地址本身都会失败（error -9）：先刷新签名再申请地址
    await _ensureFreshStreamSignature();
    // 刷新签名会替换 detail，取流参数必须取自刷新后的详情，否则这次刷新等于白做
    final freshDetail = detail.value ?? roomDetail;
    try {
      var playUrl = await site.liveSite.getPlayUrls(
        detail: freshDetail,
        quality: qualites[currentQuality],
      );
      if (playUrl.urls.isEmpty) {
        Log.w("获取播放地址为空");
        schedulePlaybackRecover("获取播放地址失败");
        return;
      }
      // 整体替换地址列表：中途失败时旧线路信息仍然完整可用
      playUrls.value = playUrl.urls;
      playHeaders = playUrl.headers;
    } catch (e) {
      Log.logPrint(e);
      schedulePlaybackRecover("获取播放地址异常");
      return;
    }
    // 地址列表变化后线路下标越界时回到第一条
    if (currentLineIndex < 0 || currentLineIndex >= playUrls.length) {
      currentLineIndex = 0;
    }
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    setPlayer();
  }

  void changePlayLine(int index) {
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    // 地址带时效，切换线路同样重新申请，避免重放旧地址
    getPlayUrl(resetLine: false);
  }

  void setPlayer() async {
    if (playUrls.isEmpty) {
      Log.w("没有可用播放地址，无法打开播放");
      schedulePlaybackRecover("没有可用播放地址");
      return;
    }
    // 线路下标可能来自外部切换，打开前先夹到合法范围
    final lineIndex = currentLineIndex.clamp(0, playUrls.length - 1);
    currentLineIndex = lineIndex;
    currentLineInfo.value = "线路${lineIndex + 1}";
    errorMsg.value = "";
    // 先启动看门狗：open 抛异常时恢复链仍需运行（该方法幂等）
    startPlaybackWatchdog();
    try {
      // 初始化播放器并设置 ao 参数
      await initializePlayer();
      await player.open(
        Media(
          playUrls[lineIndex],
          httpHeaders: playHeaders,
        ),
      );
    } catch (e) {
      Log.logPrint(e);
      schedulePlaybackRecover("打开播放失败");
      return;
    }
    Log.d("播放链接\r\n：${playUrls[lineIndex]}");
    // 地址带 expire 时提前刷新，避免到期被 CDN 断开
    schedulePlayUrlRefresh();
  }

  @override
  void mediaEnd() {
    super.mediaEnd();
    recoverPlayback("播放结束");
  }

  @override
  void mediaError(String error) {
    super.mediaError(error);
    recoverPlayback("播放失败：$error");
  }

  @override
  void mediaStalled() {
    recoverPlayback("播放停滞");
  }

  /// 播放异常后的恢复流程。
  ///
  /// 每条线路分两级：先原地重建（复用缓存的地址，不发站点请求），原地重建无效才
  /// 重新向站点申请地址；当前线路连续失败后再切换到下一条线路。
  ///
  /// 之所以把重新申请地址放到第二级：断流多为连接层问题，原地重建代价更小；且
  /// 高频申请地址会被风控，一旦被风控连正确签名的地址都拿不到，恢复链反而彻底失效。
  ///
  /// 能走到这里说明此前确实播放过：即使当前标记为未开播也尝试恢复，「流断开」
  /// 与「主播下播」无法仅凭播放状态区分，交由后续确认流程处理。
  void recoverPlayback(String reason) {
    if (isClosed) {
      return;
    }
    final now = DateTime.now();
    final lastRecoverAt = _lastRecoverAt;
    // 冷却期内的重复触发直接丢弃：error 风暴不能变成站点请求风暴
    if (lastRecoverAt != null &&
        now.difference(lastRecoverAt) < _recoverCooldown) {
      Log.w("$reason，距上次恢复不足 ${_recoverCooldown.inSeconds} 秒，跳过本次");
      return;
    }
    _lastRecoverAt = now;
    // 已有待触发的退避重试时，恢复节奏交给定时器：否则 error 风暴会借这条快路径
    // 每 5 秒（冷却窗口）再发一轮取流请求，仍然足以触发风控。
    final pendingRetry = _playbackRecoverTimer;
    if (pendingRetry != null && pendingRetry.isActive) {
      Log.d("$reason，已有待触发的重试，交由退避定时器恢复");
      return;
    }
    // 预算耗尽后不再发起任何站点请求：否则每秒数条 error 会演变成持续请求风暴
    if (_recoverRetryCount >= _recoverRetryLimit) {
      Log.w("$reason，重试次数已达上限，等待手动刷新或画面恢复");
      return;
    }
    if (mediaErrorRetryCount < _maxRetryPerLine) {
      mediaErrorRetryCount += 1;
      // 直播断流多为连接层问题（CDN 抖动、TCP 断开），缓存地址往往仍然有效：原地
      // 重建就能恢复且会从最新位置续播，代价只是一次播放器重开，不发站点请求；
      // 高频申请地址会被风控，连正确签名的地址都拿不到，恢复链反而彻底失效。
      if (mediaErrorRetryCount == 1 && playUrls.isNotEmpty) {
        Log.w("$reason，第$mediaErrorRetryCount 次原地重新打开播放器");
        setPlayer();
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

  /// 播放全部失败后确认房间真实状态。
  ///
  /// 直播流断开（CDN 切换、网络抖动、地址过期）与主播下播都会让播放结束，
  /// 仅凭播放失败无法区分；确认仍在直播时继续重试，避免误报「未开播」。
  /// 录播房间 status 为 false 但仍有可播放的流，因此把 isRecord 也算作在播，
  /// 与 loadData 的判定保持一致。查询抛异常不等于下播（网络问题同样会抛错），
  /// 只有明确 status=false 且非录播才认定直播已结束。
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
      // 确认失败不等于下播：网络异常同样会抛错，继续重试而不是误报直播结束
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
  /// 站点对高频请求会触发风控（返回异常数据结构），因此间隔逐次拉长。
  static const List<int> _recoverRetrySeconds = [20, 30, 45, 60, 90, 120];

  /// 连续确认主播在播但仍无法播放的最大重试次数。
  static const int _recoverRetryLimit = 30;

  /// 已连续重试恢复播放的次数。
  ///
  /// 达到上限后保留该计数而不重置：重置会让「30 次上限」形同虚设并无限重连，
  /// 只有画面确认恢复或用户重新进入房间才清零。
  int _recoverRetryCount = 0;

  /// 重试预算耗尽后的保活重试间隔。
  ///
  /// 长时间挂机（TV/桌面端）时用户不在场：彻底停止自动重连会让「主播仍在播、
  /// 网络稍后恢复」的画面永久停在失败状态，因此保留一条极低频的自愈路径。
  /// 间隔必须远大于退避上限：请求量低到不会再触发站点风控，又能等到网络恢复。
  static const Duration _recoverKeepAliveInterval = Duration(minutes: 5);

  /// 上一次发起恢复尝试的时刻，用于冷却判断。
  DateTime? _lastRecoverAt;

  /// 两次恢复尝试之间的最小间隔。
  ///
  /// mpv 断流时每秒会产生 5~12 条 error，逐条发起站点请求会瞬间达到每秒
  /// 二十次以上并触发风控，因此冷却期内的重复触发一律丢弃。
  static const Duration _recoverCooldown = Duration(seconds: 5);

  /// 播放全部失败后的重试定时器。
  Timer? _playbackRecoverTimer;

  /// 播放地址刷新定时器。
  Timer? _playUrlRefreshTimer;

  /// 提前刷新播放地址的余量（秒）。
  static const int _playUrlRefreshLeadSeconds = 45;

  /// 安排主动刷新所需的最短剩余有效期（秒）。
  ///
  /// 剩余时间只比提前量略长时刷新会立刻触发，这种短命地址交给恢复链处理，
  /// 避免刚安排就刷新的请求抖动。
  static const int _playUrlRefreshMinSeconds = _playUrlRefreshLeadSeconds * 2;

  /// 当前适用的恢复重试间隔。
  Duration get _recoverRetryInterval {
    final index = _recoverRetryCount.clamp(0, _recoverRetrySeconds.length - 1);
    return Duration(seconds: _recoverRetrySeconds[index]);
  }

  /// 安排稍后重新尝试恢复播放。
  ///
  /// 获取播放地址失败等场景使用：此时不能中断恢复链，必须留下后续重试。
  void schedulePlaybackRecover(String reason) {
    _armRecoverTimer(reason);
  }

  /// 统一的重试入口。
  ///
  /// 所有自动恢复路径都必须经过这里：各路径各自起定时器会绕过重试预算。
  /// 幂等：已有待触发的重试时只记日志、不重建也不增加计数——断流时每秒数条
  /// error 会把退避定时器不断重置，间隔再长也永远等不到触发（恢复活锁）。
  void _armRecoverTimer(String reason) {
    if (isClosed) {
      return;
    }
    if (_playbackRecoverTimer?.isActive ?? false) {
      Log.w("$reason，已有待触发的恢复重试，忽略本次安排");
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
    final interval = _recoverRetryInterval;
    _playbackRecoverTimer = Timer(interval, () {
      Log.d("重新尝试恢复播放（$reason）");
      mediaErrorRetryCount = 0;
      getPlayUrl(resetLine: false);
    });
    Log.w("$reason，${interval.inSeconds} 秒后重试恢复播放");
  }

  /// 解析当前线路地址的有效期，并安排在过期前主动刷新。
  ///
  /// 斗鱼等平台的地址带 expire（常见 300 秒），到期后 CDN 会主动断开连接，
  /// 表现为「看着看着就停了」；提前刷新可以避免这类中断。
  void schedulePlayUrlRefresh() {
    _playUrlRefreshTimer?.cancel();
    if (playUrls.isEmpty) {
      return;
    }
    // 实际播放的是当前线路，下标越界时才退回首条（沿用原有兜底）
    final hasCurrentLine =
        currentLineIndex >= 0 && currentLineIndex < playUrls.length;
    final currentUrl =
        hasCurrentLine ? playUrls[currentLineIndex] : playUrls.first;
    final expireSeconds = parsePlayUrlExpireSeconds(currentUrl);
    if (expireSeconds == null || expireSeconds <= _playUrlRefreshMinSeconds) {
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

  /// 每条线路的最大重试次数。
  static const int _maxRetryPerLine = 2;

  /// 当前线路已重试的次数，取到新地址或播放恢复正常后清零。
  int mediaErrorRetryCount = 0;

  @override
  void onPlaybackHealthy() {
    // 看门狗要求连续多次采样健康才回调到这里：单次推进就清零会让 5 秒级的
    // 播放抖动把 30 次重试上限耗尽。不能依赖 player.stream.playing，该事件流
    // 是 distinct 的，断流恢复时 playing 值没有变化，事件不会重发。
    final clearedRetries = _recoverRetryCount;
    mediaErrorRetryCount = 0;
    _recoverRetryCount = 0;
    _playbackRecoverTimer?.cancel();
    // 恢复健康后允许立即响应下一次真实断流，否则会在冷却窗口里被静默丢弃
    _lastRecoverAt = null;
    // 播放确实恢复，撤销可能误报的「未开播」
    if (!liveStatus.value) {
      liveStatus.value = true;
    }
    // 恢复成功没有别的可见信号，事后排查断流只能靠这条日志确认「确实自愈了」
    Log.w("画面恢复，重试预算已清零（本次重试 $clearedRetries 次）");
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
    SmartDialog.showToast("已关注");
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    // if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
    //   return;
    // }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已取消关注");
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    rxSite.value = site;
    rxRoomId.value = roomId;

    // 清除全部消息
    liveDanmaku.stop();

    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();

    // 刷新信息
    loadData();
  }

  void nextChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels
        .indexWhere((element) => element.id == "${site.id}_$roomId");
    // if (index == -1) {
    //   //当前频道不在列表中

    //   return;
    // }
    index += 1;
    if (index >= liveChannels.length) {
      index = 0;
    }
    var nextChannel = liveChannels[index];

    resetRoom(Sites.allSites[nextChannel.siteId]!, nextChannel.roomId);
  }

  void prevChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels
        .indexWhere((element) => element.id == "${site.id}_$roomId");
    // if (index == -1) {
    //   //当前频道不在列表中

    //   return;
    // }
    index -= 1;
    if (index < 0) {
      index = liveChannels.length - 1;
    }
    var nextChannel = liveChannels[index];

    resetRoom(Sites.allSites[nextChannel.siteId]!, nextChannel.roomId);
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

  @override
  void onClose() {
    // 只清理本控制器新增的定时器：看门狗由 PlayerController.onClose 统一停止
    _playbackRecoverTimer?.cancel();
    _playUrlRefreshTimer?.cancel();
    liveDanmaku.stop();

    danmakuController = null;
    super.onClose();
  }
}
