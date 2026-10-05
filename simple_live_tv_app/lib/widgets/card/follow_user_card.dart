import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/widgets/card/anchor_card.dart';
import 'package:simple_live_tv_app/widgets/highlight_widget.dart';
import 'package:simple_live_tv_app/widgets/net_image.dart';

/// 直播中的关注用户卡片：16:9 封面 + 底部信息条。
///
/// 未开播的用户仍用 [AnchorCard]（头像样式），两种卡片在关注列表中混排，
/// 让正在直播的房间靠封面就能被一眼认出，与桌面版关注列表保持一致。
class FollowUserCard extends StatelessWidget {
  /// 封面圆角，与底部信息条共用。
  static const double _cardRadius = 16;

  /// 底部头像直径。
  static const double _faceSize = 40;

  /// 头像解码宽度：按显示尺寸的 2 倍传入，避免小图按原图分辨率解码。
  static const int _faceCacheWidth = 80;

  final FollowUser item;
  final AppFocusNode? focusNode;
  final bool autofocus;
  final Function()? onTap;
  const FollowUserCard({
    required this.item,
    this.focusNode,
    this.autofocus = false,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    var site = Sites.allSites[item.siteId]!;
    var node = focusNode ?? AppFocusNode();
    return HighlightWidget(
      focusNode: node,
      autofocus: autofocus,
      borderRadius: AppStyle.radius16,
      color: Colors.white10,
      onTap: onTap ??
          () {
            AppNavigator.toLiveRoomDetail(site: site, roomId: item.roomId);
          },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(_cardRadius.w),
              topRight: Radius.circular(_cardRadius.w),
            ),
            child: Stack(
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Obx(
                    () => NetImage(item.cover.value ?? ''),
                  ),
                ),
                Positioned(
                  left: 8.w,
                  top: 8.w,
                  child: Obx(
                    () => _buildLiveBadge(node.isFoucsed.value),
                  ),
                ),
              ],
            ),
          ),
          _buildInfoBar(site.logo, site.name, node),
        ],
      ),
    );
  }

  /// 封面左上角的直播中标记，附带已开播时长。
  ///
  /// 时长跟随封面一起重建：刷新完成后才写入新的开播时间，此时封面必然
  /// 已被赋值，两者在同一帧渲染出来。
  Widget _buildLiveBadge(bool focused) {
    return Container(
      padding: AppStyle.edgeInsetsH12.copyWith(top: 6.w, bottom: 6.w),
      decoration: BoxDecoration(
        color: focused ? Colors.white : Colors.black54,
        borderRadius: AppStyle.radius8,
      ),
      child: Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Icon(
                Icons.fiber_manual_record,
                color: Colors.red,
                size: 20.w,
              ),
            ),
            const TextSpan(text: " 直播中 "),
            TextSpan(text: Utils.liveDurationToString(item.liveStartTime)),
          ],
        ),
        style: TextStyle(
          fontSize: 20.w,
          color: focused ? Colors.black : Colors.white,
        ),
      ),
    );
  }

  /// 底部信息条：头像 + 用户名 + 平台。
  Widget _buildInfoBar(String siteLogo, String siteName, AppFocusNode node) {
    return Padding(
      padding: AppStyle.edgeInsetsA12.copyWith(left: 16.w, right: 16.w),
      child: Row(
        children: [
          NetImage(
            item.face,
            width: _faceSize.w,
            height: _faceSize.w,
            borderRadius: _faceSize.w,
            cacheWidth: _faceCacheWidth,
          ),
          AppStyle.hGap12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Obx(
                  () => Text(
                    item.userName,
                    style: TextStyle(
                      fontSize: 28.w,
                      color: node.isFoucsed.value ? Colors.black : Colors.white,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                AppStyle.vGap4,
                Row(
                  children: [
                    Image.asset(siteLogo, width: 24.w),
                    AppStyle.hGap4,
                    Expanded(
                      child: Text(
                        siteName,
                        style: node.isFoucsed.value
                            ? AppStyle.subTextStyleBlack
                            : AppStyle.subTextStyleWhite,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 关注列表里的一个条目。
///
/// 正在直播的房间用 [FollowUserCard]（16:9 封面）呈现，未开播的沿用
/// [AnchorCard]（圆形头像）——两种卡片混排，靠封面就能一眼认出在播的房间。
///
/// 首页与独立关注页共用这一处实现：两处各写一份同样的条件判断时，只改了
/// 其中一处就会出现「首页换成了封面卡片、关注页还是头像卡片」这种不一致，
/// 而在电视上根本看不出差别出在哪。
class FollowUserListItem extends StatelessWidget {
  final FollowUser item;
  const FollowUserListItem({required this.item, super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => item.liveStatus.value == 2
          ? FollowUserCard(item: item)
          : AnchorCard(
              face: item.face,
              name: item.userName,
              siteId: item.siteId,
              liveStatus: item.liveStatus.value,
              roomId: item.roomId,
            ),
    );
  }
}
