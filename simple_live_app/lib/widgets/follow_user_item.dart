import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/widgets/net_image.dart';

import 'dart:ui' as ui;

class FollowUserItem extends StatelessWidget {
  final FollowUser item;
  final Function()? onRemove;
  final Function()? onTap;
  final Function()? onLongPress;
  final bool playing;
  const FollowUserItem({
    required this.item,
    this.onRemove,
    this.onTap,
    this.onLongPress,
    this.playing = false,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var site = Sites.allSites[item.siteId]!;
    // 自身订阅直播状态：本组件是无状态组件，不订阅时状态变化只能等父级整表重建，
    // 会出现"已经开播但卡片仍停留在未开播布局"的陈旧显示。
    return Obx(() {
      if (item.liveStatus.value == 2) {
        return _buildLiveCard(context, site);
      }
      return _buildListTile(context, site);
    });
  }

  Widget _buildListTile(BuildContext context, Site site) {
    return ListTile(
      contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 4),
      leading: NetImage(item.face, width: 48, height: 48, borderRadius: 24),
      title: Text.rich(
        TextSpan(
          text: item.userName,
          children: [
            WidgetSpan(
              alignment: ui.PlaceholderAlignment.middle,
              child: Obx(
                () => Offstage(
                  offstage: item.liveStatus.value == 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppStyle.hGap12,
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: item.liveStatus.value == 2
                              ? Colors.green
                              : Colors.grey,
                          borderRadius: AppStyle.radius12,
                        ),
                      ),
                      AppStyle.hGap4,
                      Text(
                        getStatus(item.liveStatus.value),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.normal,
                          color: item.liveStatus.value == 2
                              ? null
                              : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      subtitle: Wrap(
        runSpacing: 1.0,
        children: [
          Image.asset(site.logo, width: 20),
          AppStyle.hGap4,
          Text(
            site.name,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
            overflow: TextOverflow.ellipsis,
          ),
          if (playing)
            Padding(
              padding: AppStyle.edgeInsetsL8,
              child: Text(
                "正在观看",
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          else if (item.liveStatus.value == 2 && item.liveStartTime != null)
            Padding(
              padding: AppStyle.edgeInsetsL8,
              child: Text(
                '开播了${formatLiveDuration(item.liveStartTime)}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
        ],
      ),
      trailing: playing
          ? const SizedBox(
              width: 64,
              child: Center(child: Icon(Icons.play_arrow)),
            )
          : (onRemove == null
                ? null
                : IconButton(
                    onPressed: () {
                      onRemove?.call();
                    },
                    icon: const Icon(Remix.dislike_line),
                  )),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  Widget _buildLiveCard(BuildContext context, Site site) {
    return Card(
      margin: const EdgeInsets.all(3),
      clipBehavior: Clip.antiAlias,
      elevation: 1,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                children: [
                  NetImage(
                    item.cover.value ?? '',
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Colors.black54, Colors.transparent],
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.fiber_manual_record,
                            color: Colors.red,
                            size: 8,
                          ),
                          AppStyle.hGap4,
                          const Text(
                            '直播',
                            style: TextStyle(color: Colors.white, fontSize: 10),
                          ),
                          const Spacer(),
                          if (item.liveStartTime != null)
                            Text(
                              formatLiveDuration(item.liveStartTime),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 9,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 3, 2, 3),
              child: Row(
                children: [
                  NetImage(item.face, width: 20, height: 20, borderRadius: 10),
                  AppStyle.hGap4,
                  Expanded(
                    child: Text(
                      item.userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  if (item.tag != "全部")
                    Tooltip(
                      message: '长按修改标签',
                      child: GestureDetector(
                        onLongPress: onLongPress,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          margin: const EdgeInsets.only(right: 2),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Remix.price_tag_3_line,
                            size: 10,
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
                          ),
                        ),
                      ),
                    ),
                  if (onRemove != null)
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: IconButton(
                        onPressed: () => onRemove?.call(),
                        icon: const Icon(Remix.dislike_line, size: 14),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String getStatus(int status) {
    if (status == 0) {
      return "读取中";
    } else if (status == 1) {
      return "未开播";
    } else {
      return "直播中";
    }
  }

  String formatLiveDuration(String? startTimeStampString) {
    if (startTimeStampString == null ||
        startTimeStampString.isEmpty ||
        startTimeStampString == "0") {
      return "";
    }
    try {
      int startTimeStamp = int.parse(startTimeStampString);
      int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      int durationInSeconds = currentTimeStamp - startTimeStamp;

      int hours = durationInSeconds ~/ 3600;
      int minutes = (durationInSeconds % 3600) ~/ 60;

      String hourText = hours > 0 ? '$hours小时' : '';
      String minuteText = minutes > 0 ? '$minutes分钟' : '';

      if (hours == 0 && minutes == 0) {
        return "不足1分钟";
      }

      return '$hourText$minuteText';
    } catch (e) {
      Log.logPrint('格式化开播时长出错: $e');
      return "--小时--分钟";
    }
  }
}
