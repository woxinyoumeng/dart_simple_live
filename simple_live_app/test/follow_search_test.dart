import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/follow_service.dart';

/// 构造关注用户；siteId 用于验证跨平台房间号重名场景
FollowUser followUser({
  required String roomId,
  required String userName,
  String siteId = "bilibili",
  String? roomTitle,
}) {
  var user = FollowUser(
    id: "${siteId}_$roomId",
    roomId: roomId,
    siteId: siteId,
    userName: userName,
    face: "",
    addTime: DateTime(2026, 1, 1),
  );
  user.roomTitle.value = roomTitle;
  return user;
}

void main() {
  group("FollowService.isRoomIdQuery", () {
    test("纯数字按直播间号理解", () {
      expect(FollowService.isRoomIdQuery("123456"), isTrue);
    });

    test("含字母、空格或为空时不按直播间号处理", () {
      expect(FollowService.isRoomIdQuery("12a"), isFalse);
      expect(FollowService.isRoomIdQuery("123 456"), isFalse);
      expect(FollowService.isRoomIdQuery(""), isFalse);
    });
  });

  group("FollowService.matchesSearch", () {
    test("空关键词命中全部关注", () {
      var user = followUser(roomId: "100", userName: "老王");
      expect(FollowService.matchesSearch(user, "", null), isTrue);
    });

    test("按主播名匹配且忽略大小写", () {
      var user = followUser(roomId: "100", userName: "Alice直播");
      expect(FollowService.matchesSearch(user, "alice", null), isTrue);
      expect(FollowService.matchesSearch(user, "ALICE", null), isTrue);
      expect(FollowService.matchesSearch(user, "bob", null), isFalse);
    });

    test("按直播标题匹配", () {
      var user = followUser(
        roomId: "100",
        userName: "老王",
        roomTitle: "今晚八点开黑上分",
      );
      expect(FollowService.matchesSearch(user, "开黑", null), isTrue);
      expect(FollowService.matchesSearch(user, "回放", null), isFalse);
    });

    test("未开播清空标题后不会命中旧标题", () {
      var user = followUser(roomId: "100", userName: "老王", roomTitle: null);
      expect(FollowService.matchesSearch(user, "开黑", null), isFalse);
    });

    test("纯数字未选平台时不匹配房间号", () {
      var user = followUser(roomId: "100", userName: "老王");
      expect(FollowService.matchesSearch(user, "100", null), isFalse);
    });

    test("纯数字选定平台后按房间号匹配", () {
      var user = followUser(roomId: "123456", userName: "老王");
      expect(
        FollowService.matchesSearch(user, "123456", "bilibili"),
        isTrue,
      );
      expect(
        FollowService.matchesSearch(user, "2345", "bilibili"),
        isTrue,
      );
      expect(
        FollowService.matchesSearch(user, "999", "bilibili"),
        isFalse,
      );
    });

    test("房间号只在所选平台内匹配，避免跨平台重名", () {
      var sameRoom = followUser(roomId: "100", userName: "老王");
      expect(FollowService.matchesSearch(sameRoom, "100", "douyu"), isFalse);
    });

    test("主播名与标题搜索同样受平台限制", () {
      var user = followUser(roomId: "100", userName: "老王", roomTitle: "开黑");
      expect(FollowService.matchesSearch(user, "老王", "douyu"), isFalse);
      expect(FollowService.matchesSearch(user, "老王", "bilibili"), isTrue);
    });
  });
}
