import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/follow_service.dart';

/// 构造关注用户；liveStatus 取值与线上一致：0=未知 1=未开播 2=直播中
FollowUser followUser(String name, int liveStatus) {
  var user = FollowUser(
    id: "site_$name",
    roomId: name,
    siteId: "site",
    userName: name,
    face: "",
    addTime: DateTime(2026, 1, 1),
  );
  user.liveStatus.value = liveStatus;
  return user;
}

History history(String name, int? visitCount, DateTime updateTime) => History(
      id: "site_$name",
      roomId: name,
      siteId: "site",
      userName: name,
      face: "",
      updateTime: updateTime,
      visitCount: visitCount,
    );

/// 真实走一遍比较器，返回排好序的名字，避免写出恒真断言
List<String> sortedNames(
  List<FollowUser> users,
  List<History> histories, {
  bool byPreference = true,
}) {
  var index = {for (var item in histories) item.id: item};
  var list = [...users]
    ..sort((a, b) => FollowService.compareFollowUser(a, b, index, byPreference));
  return list.map((e) => e.userName).toList();
}

void main() {
  group("FollowService.compareFollowUser 按观看喜好排序", () {
    test("访问次数多的排在前面", () {
      var users = [followUser("少看", 2), followUser("常看", 2)];
      var histories = [
        history("少看", 1, DateTime(2026, 1, 9)),
        history("常看", 9, DateTime(2026, 1, 1)),
      ];

      expect(sortedNames(users, histories), ["常看", "少看"]);
    });

    test("次数相同时最近观看的排在前面", () {
      var users = [followUser("很久以前", 2), followUser("刚看过", 2)];
      var histories = [
        history("很久以前", 3, DateTime(2026, 1, 1)),
        history("刚看过", 3, DateTime(2026, 1, 9)),
      ];

      expect(sortedNames(users, histories), ["刚看过", "很久以前"]);
    });

    test("从未看过的排在看过之后", () {
      var users = [followUser("没看过", 2), followUser("看过", 2)];
      var histories = [history("看过", 1, DateTime(2026, 1, 1))];

      expect(sortedNames(users, histories), ["看过", "没看过"]);
    });

    test("旧记录没有访问次数时仍排在从未看过之前", () {
      // 旧库记录读出来 visitCount 为 null，不能因此被当成「没看过」
      var users = [followUser("没看过", 2), followUser("旧记录", 2)];
      var histories = [history("旧记录", null, DateTime(2026, 1, 1))];

      expect(sortedNames(users, histories), ["旧记录", "没看过"]);
    });

    test("直播状态优先于观看喜好", () {
      var users = [followUser("未开播但常看", 1), followUser("直播中没看过", 2)];
      var histories = [history("未开播但常看", 20, DateTime(2026, 1, 9))];

      expect(sortedNames(users, histories), ["直播中没看过", "未开播但常看"]);
    });

    test("开启开关时直播中内部再按喜好排", () {
      var users = [
        followUser("直播中少看", 2),
        followUser("未开播常看", 1),
        followUser("直播中常看", 2),
        followUser("未知", 0),
      ];
      var histories = [
        history("直播中少看", 2, DateTime(2026, 1, 9)),
        history("未开播常看", 30, DateTime(2026, 1, 9)),
        history("直播中常看", 15, DateTime(2026, 1, 2)),
      ];

      expect(sortedNames(users, histories), [
        "直播中常看",
        "直播中少看",
        "未开播常看",
        "未知",
      ]);
    });

    test("关闭开关后完全按直播状态排序", () {
      var users = [
        followUser("未开播但常看", 1),
        followUser("直播中", 2),
        followUser("未知", 0),
      ];
      var histories = [history("未开播但常看", 20, DateTime(2026, 1, 9))];

      expect(
        sortedNames(users, histories, byPreference: false),
        ["直播中", "未开播但常看", "未知"],
      );
    });

    test("关闭开关后观看记录不影响顺序", () {
      var users = [followUser("甲", 2), followUser("乙", 2)];
      var histories = [
        history("甲", 0, DateTime(2026, 1, 1)),
        history("乙", 50, DateTime(2026, 1, 9)),
      ];

      // 同状态下比较器返回 0，Dart 的排序不再重排，保持输入顺序
      expect(sortedNames(users, histories, byPreference: false), ["甲", "乙"]);
    });
  });
}
