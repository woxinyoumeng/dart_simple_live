import 'dart:async';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/services/db_service.dart';

class FollowUserService extends BasePageController<FollowUser> {
  static FollowUserService get instance => Get.find<FollowUserService>();
  StreamSubscription<dynamic>? subscription;

  RxList<FollowUser> livingList = RxList<FollowUser>();
  Timer? updateTimer;
  bool needUpdate = true;
  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      needUpdate = false;
      refreshData();
    });

    if (list.isEmpty) {
      refreshData();
    }
    initTimer();
    super.onInit();
  }

  void initTimer() {
    if (AppSettingsController.instance.autoUpdateFollowEnable.value) {
      updateTimer?.cancel();
      updateTimer = Timer.periodic(
        Duration(
          minutes:
              AppSettingsController.instance.autoUpdateFollowDuration.value,
        ),
        (timer) {
          Log.logPrint("Update Follow Timer");
          refreshData();
        },
      );
    } else {
      updateTimer?.cancel();
    }
  }

  var updatedCount = 0;
  var updating = false.obs;
  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    if (page > 1) {
      return [];
    }

    var followList = DBService.instance.getFollowList();
    if (needUpdate) {
      startUpdateStatus(followList);
    }
    needUpdate = true;
    if (followList.isEmpty) {
      updating.value = false;
    }
    return followList;
  }

  void sortList() {
    list.sort((a, b) => b.liveStatus.value.compareTo(a.liveStatus.value));
    updateLivingList();
  }

  void updateLivingList() {
    livingList.assignAll(list.where((x) => x.liveStatus.value == 2));
  }

  void startUpdateStatus(List<FollowUser> followList) async {
    updatedCount = 0;
    updating.value = true;

    var threadCount =
        AppSettingsController.instance.updateFollowThreadCount.value;

    var tasks = <Future>[];
    for (var i = 0; i < threadCount; i++) {
      tasks.add(
        Future(() async {
          var start = i * followList.length ~/ threadCount;
          var end = (i + 1) * followList.length ~/ threadCount;

          // 确保 end 不超出列表长度
          if (end > followList.length) {
            end = followList.length;
          }
          var items = followList.sublist(start, end);
          for (var item in items) {
            await updateLiveStatus(item);
          }
        }),
      );
    }
    await Future.wait(tasks);
  }

  /// 刷新单个房间的直播状态与封面。
  ///
  /// 状态与详情分两次请求、各自容错：详情只用来补封面和开播时间，它失败时
  /// 不能把已经查到的「正在直播」一起抹掉——否则直播中的房间会退回未开播
  /// 卡片，用户看到的就是「封面没了、直播中标记也没了」。
  Future updateLiveStatus(FollowUser item) async {
    try {
      await _refreshLiveStatus(item);
    } finally {
      _markUpdated();
    }
  }

  /// 查询并写入直播状态、封面与开播时间。
  Future<void> _refreshLiveStatus(FollowUser item) async {
    // 关注列表的数据来自本地库，平台标识可能是旧版本写入的；取不到站点时
    // 直接按未知处理，避免在刷新线程里抛异常中断整批更新
    var site = Sites.allSites[item.siteId];
    if (site == null) {
      Log.w("未知平台，跳过状态刷新：${item.siteId}");
      item.liveStatus.value = 0;
      item.liveStartTime = null;
      item.cover.value = null;
      return;
    }
    final bool isLiving;
    try {
      isLiving = await site.liveSite.getLiveStatus(roomId: item.roomId);
    } catch (e) {
      Log.w("查询直播状态失败：${item.userName}（${item.siteId}）$e");
      item.liveStatus.value = 0;
      item.liveStartTime = null;
      item.cover.value = null;
      return;
    }
    if (!isLiving) {
      item.liveStatus.value = 1;
      item.liveStartTime = null;
      item.cover.value = null;
      return;
    }
    // 状态已经确定是「直播中」，先落状态再去补详情：详情失败只影响封面与
    // 开播时长，不该反过来改变状态
    item.liveStatus.value = 2;
    try {
      var detail = await site.liveSite.getRoomDetail(roomId: item.roomId);
      item.liveStartTime = detail.showTime;
      item.cover.value = detail.cover;
    } catch (e) {
      Log.w("查询直播间详情失败：${item.userName}（${item.siteId}）$e");
      item.liveStartTime = null;
      item.cover.value = null;
    }
  }

  /// 记录一个房间刷新完成；全部完成后统一排序并收起刷新状态。
  void _markUpdated() {
    updatedCount++;
    if (updatedCount >= list.length) {
      sortList();
      updating.value = false;
    }
  }

  void removeItem(FollowUser item, {bool refresh = true}) async {
    var result =
        await Utils.showAlertDialog("确定要取消关注${item.userName}吗?", title: "取消关注");
    if (!result) {
      return;
    }
    await DBService.instance.followBox.delete(item.id);
    if (refresh) {
      refreshData();
    } else {
      list.remove(item);
      livingList.remove(item);
    }
  }

  @override
  void onClose() {
    updateTimer?.cancel();
    subscription?.cancel();

    super.onClose();
  }
}
