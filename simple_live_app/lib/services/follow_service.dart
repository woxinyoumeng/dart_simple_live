import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';

class FollowService extends GetxService {
  /// 自动并发数上限。
  ///
  /// 关注列表动辄数十上百人，单条请求又要 1~3 秒，上限过低会让一次刷新
  /// 排成好几轮串行等待；配合下面按平台交错，落到单个平台的并发仍在可控范围。
  static const int maxAutoConcurrency = 40;

  StreamSubscription<dynamic>? subscription;
  static FollowService get instance => Get.find<FollowService>();

  final StreamController _updatedListController = StreamController.broadcast();
  Stream get updatedListStream => _updatedListController.stream;

  /// 关注用户列表
  RxList<FollowUser> followList = RxList<FollowUser>();

  /// 直播中的用户列表
  RxList<FollowUser> liveList = RxList<FollowUser>();

  /// 未直播的用户列表
  RxList<FollowUser> notLiveList = RxList<FollowUser>();

  /// 用户自定义的tag
  RxList<FollowUserTag> followTagList = RxList<FollowUserTag>();

  /// 观看记录索引，「房间 id → 观看记录」；排序比较器逐次查库会放大开销
  Map<String, History> _historyIndex = {};

  Map<String, History> _buildHistoryIndex() {
    var index = <String, History>{};
    for (var history in DBService.instance.getHistores()) {
      index[history.id] = history;
    }
    return index;
  }

  /// 按观看喜好排序：先直播状态，再累计访问次数，最后最近观看时间。
  /// [historyById] 为「房间 id → 观看记录」索引；[byPreference] 为设置开关，
  /// 关闭时退化为仅按直播状态排序（保持原有顺序）
  static int compareFollowUser(
    FollowUser a,
    FollowUser b,
    Map<String, History> historyById,
    bool byPreference,
  ) {
    var liveCompare = b.liveStatus.value.compareTo(a.liveStatus.value);
    if (!byPreference || liveCompare != 0) {
      return liveCompare;
    }
    var historyA = historyById[a.id];
    var historyB = historyById[b.id];
    var countCompare =
        (historyB?.visitCount ?? 0).compareTo(historyA?.visitCount ?? 0);
    if (countCompare != 0) {
      return countCompare;
    }
    var timeA = historyA?.updateTime;
    var timeB = historyB?.updateTime;
    if (timeA == null && timeB == null) {
      return 0;
    }
    // 从未看过的排在看过之后
    if (timeA == null) {
      return 1;
    }
    if (timeB == null) {
      return -1;
    }
    return timeB.compareTo(timeA);
  }

  /// 直播间号关键词判定：纯数字按房间号理解
  static final RegExp _roomIdPattern = RegExp(r'^\d+$');

  static bool isRoomIdQuery(String query) => _roomIdPattern.hasMatch(query);

  /// 判断关注项是否命中搜索，供关注页搜索结果过滤使用。
  ///
  /// [query] 需已 trim；[siteId] 为 null 表示不限平台。
  /// 纯数字关键词按直播间号匹配，此时必须指定平台：不同平台的房间号会重名，
  /// 未选平台时不做房间号匹配（交给页面提示用户先选平台）；
  /// 其余关键词匹配主播名与当前直播标题，忽略大小写。
  static bool matchesSearch(FollowUser item, String query, String? siteId) {
    if (query.isEmpty) {
      return true;
    }
    if (siteId != null && item.siteId != siteId) {
      return false;
    }
    var lowerQuery = query.toLowerCase();
    if (isRoomIdQuery(query)) {
      return siteId != null && item.roomId.toLowerCase().contains(lowerQuery);
    }
    return item.userName.toLowerCase().contains(lowerQuery) ||
        (item.roomTitle.value?.toLowerCase().contains(lowerQuery) ?? false);
  }

  /// 当前tag的用户列表
  RxList<FollowUser> curTagFollowList = RxList<FollowUser>();

  /// 是否正在更新
  var updating = false.obs;

  Timer? updateTimer;

  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      loadData(updateStatus: false);
    });
    initTimer();
    super.onInit();
  }

  // 添加标签
  Future<void> addFollowUserTag(String tag) async {
    // 判断待添加tag是否已存在，存在则return
    if (followTagList.any((item) => item.tag == tag)) {
      SmartDialog.showToast("标签名重复，修改失败");
      return;
    }
    FollowUserTag item = await DBService.instance.addFollowTag(tag);
    followTagList.add(item);
  }

  // 删除标签
  Future<void> delFollowUserTag(FollowUserTag tag) async {
    followTagList.remove(tag);
    await DBService.instance.deleteFollowTag(tag.id);
  }

  // 获取用户自定义标签列表
  void getAllTagList() {
    var list = DBService.instance.getFollowTagList();
    followTagList.assignAll(list);
  }

  // 修改标签
  void updateFollowUserTag(FollowUserTag tag) {
    DBService.instance.updateFollowTag(tag);
    // 查找并修改
    var index = followTagList.indexWhere((oTag) => oTag.id == tag.id);
    followTagList[index] = tag;
  }

  // 根据标签筛选数据
  void filterDataByTag(FollowUserTag tag) {
    curTagFollowList.clear();
    // 先建一次索引：在标签内逐个线性查找的代价是「标签数 × 关注数」，
    // 关注量大时每次切换标签都会明显卡顿
    final followById = {for (var user in followList) user.id: user};
    // 用 Set 判断待删除项，避免 removeWhere 内部再做一次线性 contains
    final toRemove = <String>{};
    for (var id in tag.userId) {
      final follow = followById[id];
      if (follow == null) {
        // 标记要删除的 id
        toRemove.add(id);
      } else {
        // 找到对应的 followUser 添加到 curTagFollowList
        curTagFollowList.add(follow);
      }
    }
    // 双向确认用户取消关注后标签内是否还有该用户
    // 在遍历结束后统一移除不在 followList 中的 id
    if (toRemove.isNotEmpty) {
      tag.userId.removeWhere(toRemove.contains);
      // 更新数据库
      DBService.instance.updateFollowTag(tag);
    }
    // 标签内排序：与主列表同一套规则；索引为空而开关开启时补建一次
    var byPreference =
        AppSettingsController.instance.followSortByPreference.value;
    if (byPreference && _historyIndex.isEmpty) {
      _historyIndex = _buildHistoryIndex();
    }
    curTagFollowList.sort(
      (a, b) => compareFollowUser(a, b, _historyIndex, byPreference),
    );
  }

  // 添加关注
  Future<void> addFollow(FollowUser follow) async {
    await DBService.instance.addFollow(follow);
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
          loadData();
        },
      );
    } else {
      updateTimer?.cancel();
    }
  }

  Future<void> loadData({bool updateStatus = true}) async {
    var list = DBService.instance.getFollowList();
    getAllTagList();
    if (list.isEmpty) {
      updating.value = false;
      followList.assignAll(list);
      return;
    }
    followList.assignAll(list);
    if (updateStatus) {
      startUpdateStatus();
    }
  }

  /// 获取最优并发数
  /// 根据 CPU 核心数和用户设置自动计算
  int getOptimalConcurrency() {
    var userSetting =
        AppSettingsController.instance.updateFollowThreadCount.value;

    // 如果用户设置为 0，则自动根据 CPU 核心数计算
    if (userSetting == 0) {
      var cpuCount = Platform.numberOfProcessors;
      // 网络 I/O 密集型任务，并发数可以是 CPU 核心数的 2-3 倍
      var optimal = (cpuCount * 2.5).round();
      // 上限过低时，数十人的列表会被排成好几轮串行等待
      return optimal.clamp(4, maxAutoConcurrency);
    }

    return userSetting;
  }

  /// 按平台交错排列，避免单一平台阻塞
  List<FollowUser> interleaveByPlatform(List<FollowUser> list) {
    // 按平台分组
    var grouped = <String, Queue<FollowUser>>{};
    for (var item in list) {
      grouped.putIfAbsent(item.siteId, () => Queue<FollowUser>()).add(item);
    }

    // 交错处理
    var result = <FollowUser>[];
    while (grouped.values.any((queue) => queue.isNotEmpty)) {
      for (var queue in grouped.values) {
        if (queue.isNotEmpty) {
          result.add(queue.removeFirst());
        }
      }
    }

    return result;
  }

  void startUpdateStatus() async {
    // 定时器、事件总线、关注页下拉、直播间的关注面板都会触发这里。
    // 没有互斥时多次触发会并发执行：同一批用户被重复请求，
    // 且各自的完成状态互相踩踏，表现为刷新耗时翻倍或一直转圈。
    if (updating.value) {
      Log.logPrint("关注状态更新已在进行中，本次触发已跳过");
      return;
    }
    updating.value = true;

    var concurrency = getOptimalConcurrency();

    Log.logPrint("开始更新关注状态，并发数: $concurrency，总数: ${followList.length}");

    // 按平台交错排列，避免单一平台阻塞
    var interleavedList = interleaveByPlatform(followList);

    // 创建任务队列
    var taskQueue = Queue<FollowUser>.from(interleavedList);

    // 工作函数 - 持续从队列中取任务执行
    Future<void> worker(int workerId) async {
      while (taskQueue.isNotEmpty) {
        var item = taskQueue.removeFirst();
        await updateLiveStatus(item);
      }
    }

    // 启动固定数量的并发 worker
    var workers = <Future>[];
    for (var i = 0; i < concurrency; i++) {
      workers.add(worker(i));
    }

    try {
      await Future.wait(workers);
    } finally {
      // 无论中途是否出错都要复位，否则刷新入口会被永久锁死
      filterData();
      updating.value = false;
    }

    Log.logPrint("关注状态更新完成");
  }

  Future updateLiveStatus(FollowUser item) async {
    try {
      var site = Sites.allSites[item.siteId]!;
      // 先只查状态
      var isLiving = await site.liveSite.getLiveStatus(roomId: item.roomId);
      item.liveStatus.value = isLiving ? 2 : 1;
      if (item.liveStatus.value == 2) {
        // 只有正在直播时才查详细信息
        var detail = await site.liveSite.getRoomDetail(roomId: item.roomId);
        item.liveStartTime = detail.showTime;
        item.cover.value = detail.cover;
        item.roomTitle.value = detail.title;
      } else {
        item.liveStartTime = null;
        item.cover.value = null;
        item.roomTitle.value = null;
      }
    } catch (e) {
      Log.logPrint(e);
      item.liveStatus.value = 0;
      item.liveStartTime = null;
      item.cover.value = null;
      item.roomTitle.value = null;
    }
  }

  void filterData() {
    var byPreference =
        AppSettingsController.instance.followSortByPreference.value;
    // 只构造类内比较器所需的索引，开关关闭时不遍历观看记录
    _historyIndex = byPreference ? _buildHistoryIndex() : {};
    followList.sort(
      (a, b) => compareFollowUser(a, b, _historyIndex, byPreference),
    );
    liveList.assignAll(followList.where((x) => x.liveStatus.value == 2));
    notLiveList.assignAll(followList.where((x) => x.liveStatus.value == 1));
    _updatedListController.add(0);
  }

  void exportFile() async {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }

    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }

      var dir = "";
      if (Platform.isIOS) {
        dir = (await getApplicationDocumentsDirectory()).path;
      } else {
        dir = await FilePicker.platform.getDirectoryPath() ?? "";
      }

      if (dir.isEmpty) {
        return;
      }
      var jsonFile = File(
        '$dir/SimpleLive_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.json',
      );
      var jsonText = generateJson();
      await jsonFile.writeAsString(jsonText);
      SmartDialog.showToast("已导出关注列表");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导出失败：$e");
    }
  }

  void inputFile() async {
    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }
      var file = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null) {
        return;
      }
      var jsonFile = File(file.files.single.path!);
      await inputJson(await jsonFile.readAsString());
      SmartDialog.showToast("导入成功");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导入失败:$e");
    } finally {
      loadData();
    }
  }

  void exportText() {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }
    var content = generateJson();
    Get.dialog(
      AlertDialog(
        title: const Text("导出为文本"),
        content: TextField(
          controller: TextEditingController(text: content),
          decoration: const InputDecoration(border: OutlineInputBorder()),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () {
              Utils.copyToClipboard(content);
              Get.back();
            },
            child: const Text("复制"),
          ),
        ],
      ),
    );
  }

  void inputText() async {
    final TextEditingController textController = TextEditingController();
    await Get.dialog(
      AlertDialog(
        title: const Text("从文本导入"),
        content: TextField(
          controller: textController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: "请输入内容",
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () async {
              var content = await Utils.getClipboard();
              if (content != null) {
                textController.text = content;
              }
            },
            child: const Text("粘贴"),
          ),
          TextButton(
            onPressed: () async {
              if (textController.text.isEmpty) {
                SmartDialog.showToast("内容为空");
                return;
              }
              try {
                await inputJson(textController.text);
                SmartDialog.showToast("导入成功");
                Get.back();
                loadData();
              } catch (e) {
                SmartDialog.showToast("导入失败，请检查内容是否正确");
              }
            },
            child: const Text("导入"),
          ),
        ],
      ),
    );
  }

  String generateJson() {
    var data = followList
        .map(
          (item) => {
            "siteId": item.siteId,
            "id": item.id,
            "roomId": item.roomId,
            "userName": item.userName,
            "face": item.face,
            "addTime": item.addTime.toString(),
            "tag": item.tag,
          },
        )
        .toList();
    return jsonEncode(data);
  }

  Future inputJson(String content) async {
    var data = jsonDecode(content);

    for (var item in data) {
      var follow = FollowUser.fromJson(item);
      // 导入关注列表同时导入标签列表 此方法可优化为所有导入逻辑
      if (follow.tag != "全部") {
        // logic: 尝试添加，存在则返回已存在的对象
        var tag = await DBService.instance.addFollowTag(follow.tag);
        // 更新tag
        tag.userId.addIf(!tag.userId.contains(follow.id), follow.id);
        await DBService.instance.updateFollowTag(tag);
      }
      await DBService.instance.addFollow(follow);
    }
  }

  @override
  void onClose() {
    updateTimer?.cancel();
    subscription?.cancel();
    super.onClose();
  }
}
