// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';

class FollowUserController extends BasePageController<FollowUser> {
  StreamSubscription<dynamic>? onUpdatedIndexedStream;
  StreamSubscription<dynamic>? onUpdatedListStream;

  /// 0:全部 1:直播中 2:未直播
  var filterMode = FollowUserTag(id: "0", tag: "全部", userId: []).obs;
  RxList<FollowUserTag> tagList = [
    FollowUserTag(id: "0", tag: "全部", userId: []),
    FollowUserTag(id: "1", tag: "直播中", userId: []),
    FollowUserTag(id: "2", tag: "未开播", userId: []),
  ].obs;

  // 用户自定义标签
  RxList<FollowUserTag> userTagList = <FollowUserTag>[].obs;

  /// 是否处于搜索模式；搜索范围是全部关注，不受标签/直播状态筛选影响
  var searching = false.obs;

  /// 搜索关键词：主播名 / 直播标题 / 直播间号
  var searchQuery = "".obs;

  /// 搜索限定的平台；null 表示全部平台
  var searchSiteId = RxnString();

  /// 当前标签/直播状态筛选命中的关注，搜索关闭时直接作为列表数据
  List<FollowUser> _filteredList = [];

  @override
  void onInit() {
    onUpdatedIndexedStream = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 1) {
          scrollToTopOrRefresh();
        }
      },
    );
    onUpdatedListStream =
        FollowService.instance.updatedListStream.listen((event) {
      filterData();
    });
    super.onInit();
  }

  @override
  Future refreshData() async {
    await FollowService.instance.loadData();
    updateTagList();
    super.refreshData();
  }

  @override
  Future loadData() async {
    await super.loadData();
    // loadData 会把非空结果标记为可加载更多，搜索态需要重新压掉这个入口
    if (searching.value) {
      canLoadMore.value = false;
    }
  }

  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    if (page > 1) {
      return Future.value([]);
    }
    if (searching.value) {
      return _searchResult();
    }
    _filteredList = _pickByFilterMode();
    return _filteredList;
  }

  void updateTagList() {
    userTagList.assignAll(FollowService.instance.followTagList);
    tagList.value = tagList.take(3).toList();
    for (var i in userTagList) {
      if (!tagList.contains(i)) {
        tagList.add(i);
      }
    }
  }

  void filterData() {
    _filteredList = _pickByFilterMode();
    applySearch();
  }

  /// 按当前标签/直播状态取关注数据
  List<FollowUser> _pickByFilterMode() {
    if (filterMode.value.tag == "全部") {
      return FollowService.instance.followList.value;
    } else if (filterMode.value.tag == "直播中") {
      return FollowService.instance.liveList.value;
    } else if (filterMode.value.tag == "未开播") {
      return FollowService.instance.notLiveList.value;
    } else {
      FollowService.instance.filterDataByTag(filterMode.value);
      return FollowService.instance.curTagFollowList;
    }
  }

  /// 应用搜索条件：搜索态下范围是全部关注，关闭搜索后回到标签筛选结果
  void applySearch() {
    if (searching.value) {
      list.assignAll(_searchResult());
      // PageGridView 靠 pageEmpty 显示空态，搜索无结果需要提示而不是静默空白
      pageEmpty.value = list.isEmpty;
      // 搜索是本地一次性过滤，没有下一页；不关闭会在桌面端残留"加载更多"
      canLoadMore.value = false;
    } else {
      list.assignAll(_filteredList);
      pageEmpty.value = false;
    }
  }

  List<FollowUser> _searchResult() {
    var query = searchQuery.value.trim();
    var siteId = searchSiteId.value;
    return FollowService.instance.followList
        .where((item) => FollowService.matchesSearch(item, query, siteId))
        .toList();
  }

  void startSearch() {
    searching.value = true;
    applySearch();
  }

  void stopSearch() {
    searching.value = false;
    searchQuery.value = "";
    searchSiteId.value = null;
    applySearch();
    // 还原搜索前由 loadData 设置的分页入口状态
    canLoadMore.value = _filteredList.isNotEmpty;
  }

  void setSearchQuery(String query) {
    searchQuery.value = query;
    applySearch();
  }

  /// [siteId] 为 null 表示全部平台
  void setSearchSite(String? siteId) {
    searchSiteId.value = siteId;
    applySearch();
  }

  void setFilterMode(FollowUserTag tag) {
    filterMode.value = tag;
    filterData();
  }

  void removeItem(FollowUser item) async {
    var result =
        await Utils.showAlertDialog("确定要取消关注${item.userName}吗?", title: "取消关注");
    if (!result) {
      return;
    }
    // 取消关注同时删除标签内的 userId
    if (item.tag != "全部") {
      var tag = tagList.firstWhere((tag) => tag.tag == item.tag);
      tag.userId.remove(item.id);
      updateTag(tag);
    }
    await DBService.instance.followBox.delete(item.id);
    refreshData();
  }

  void updateItem(FollowUser item) {
    FollowService.instance.addFollow(item);
  }

  // 修改item的标签
  void setItemTag(FollowUser item, FollowUserTag targetTag) {
    FollowUserTag tarTag = targetTag;
    FollowUserTag curTag = tagList.firstWhere((tag) => tag.tag == item.tag);
    // 从当前标签（非全部）删除item 向目标标签(全部包含所有item == 非全部)添加item
    curTag.userId.remove(item.id);
    tarTag.userId.addIf(!tarTag.userId.contains(item.id), item.id);
    // 数据库更新
    item.tag = tarTag.tag;
    updateTag(curTag);
    updateTag(tarTag);
    updateItem(item);
    filterData();
  }

  Future<void> removeTag(FollowUserTag tag) async {
    // 将tag下的所有follow设置为全部
    for (var i in tag.userId) {
      var follow = DBService.instance.followBox.get(i);
      if (follow != null) {
        follow.tag = "全部";
        updateItem(follow);
      }
    }
    await FollowService.instance.delFollowUserTag(tag);
    updateTagList();
    Log.i('删除tag${tag.tag}');
  }

  void addTag(String tag) async {
    FollowService.instance
        .addFollowUserTag(tag)
        .then((value) => updateTagList());
  }

  void updateTag(FollowUserTag followUserTag) {
    if (followUserTag.tag == '全部') {
      return;
    }
    FollowService.instance.updateFollowUserTag(followUserTag);
  }

  void updateTagName(FollowUserTag followUserTag, String newTagName) {
    // 未操作
    if (followUserTag.tag == newTagName) {
      return;
    }
    // 避免重名
    if (tagList.any((item) => item.tag == newTagName)) {
      SmartDialog.showToast("标签名重复，修改失败");
      return;
    }
    final FollowUserTag newTag = followUserTag.copyWith(tag: newTagName);
    updateTag(newTag);
    // update item's tag when update tagName
    for (var i in newTag.userId) {
      var follow = DBService.instance.followBox.get(i);
      if (follow != null) {
        follow.tag = newTagName;
        updateItem(follow);
      }
    }
    SmartDialog.showToast("标签名修改成功");
    updateTagList();
  }

  // 调整标签顺序
  void updateTagOrder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1; // 处理索引调整
    final item = userTagList.removeAt(oldIndex);
    userTagList.insert(newIndex, item);
    tagList.value = tagList.take(3).toList();
    tagList.addAll(userTagList);
    DBService.instance.updateFollowTagOrder(userTagList);
  }

  @override
  void onClose() {
    onUpdatedIndexedStream?.cancel();
    super.onClose();
  }
}
