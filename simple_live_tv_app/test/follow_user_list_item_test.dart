import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/widgets/card/anchor_card.dart';
import 'package:simple_live_tv_app/widgets/card/follow_user_card.dart';

/// 用 TV 版 main.dart 相同的设计尺寸初始化 ScreenUtil，否则 `.w` 无法取值。
Widget _wrap(Widget child) {
  return ScreenUtilInit(
    designSize: const Size(1920, 1080),
    builder: (context, _) => MaterialApp(home: Scaffold(body: child)),
  );
}

/// 直播状态：未开播。
const int _notLiving = 1;

/// 直播状态：直播中。
const int _living = 2;

/// 构造一个关注用户。
///
/// 平台标识必须是 [Sites.allSites] 里存在的键，卡片会据此取站点名称与图标；
/// 头像与封面用网络地址，让图片按加载失败处理而不是去找不存在的本地资源。
FollowUser _item() => FollowUser(
      id: "bilibili_1",
      roomId: "1",
      siteId: "bilibili",
      userName: "测试主播",
      face: "https://example.com/face.png",
      addTime: DateTime.now(),
    )..cover.value = "https://example.com/cover.png";

void main() {
  testWidgets('直播中的房间渲染为封面卡片', (WidgetTester tester) async {
    final item = _item()..liveStatus.value = _living;

    await tester.pumpWidget(_wrap(FollowUserListItem(item: item)));

    expect(find.byType(FollowUserCard), findsOneWidget);
    expect(find.byType(AnchorCard), findsNothing);
  });

  testWidgets('未开播的房间渲染为头像卡片', (WidgetTester tester) async {
    final item = _item()..liveStatus.value = _notLiving;

    await tester.pumpWidget(_wrap(FollowUserListItem(item: item)));

    expect(find.byType(AnchorCard), findsOneWidget);
    expect(find.byType(FollowUserCard), findsNothing);
  });

  testWidgets('状态未知时按未开播处理，不给未开播的房间配封面', (WidgetTester tester) async {
    // 状态未知（0）是刷新完成前的初始值，此时封面还没请求回来，
    // 若按直播中渲染会先闪一张空白封面卡片
    final item = _item()..liveStatus.value = 0;

    await tester.pumpWidget(_wrap(FollowUserListItem(item: item)));

    expect(find.byType(AnchorCard), findsOneWidget);
    expect(find.byType(FollowUserCard), findsNothing);
  });

  testWidgets('刷新过程中卡片类型跟着状态切换', (WidgetTester tester) async {
    final item = _item()..liveStatus.value = 0;

    await tester.pumpWidget(_wrap(FollowUserListItem(item: item)));
    expect(find.byType(AnchorCard), findsOneWidget);

    // 状态查询返回「直播中」，卡片应就地换成封面卡片
    item.liveStatus.value = _living;
    await tester.pumpWidget(_wrap(FollowUserListItem(item: item)));

    expect(find.byType(FollowUserCard), findsOneWidget);
    expect(find.byType(AnchorCard), findsNothing);
  });
}
