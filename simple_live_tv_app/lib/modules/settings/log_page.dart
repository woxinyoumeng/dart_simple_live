import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/widgets/app_scaffold.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';

/// 运行日志页。
///
/// TV 端通常接不上 adb，播放黑屏、封面取不到这类问题只能靠在电视上直接读
/// 日志定位，所以把 [Log] 在内存里保留的最近若干条日志显示出来。
///
/// 这里不用 Obx 订阅日志列表：直播播放期间每 5 秒就会刷进几条采样日志，
/// 逐条触发的整页重建会和播放抢资源；改用固定间隔刷新，把重建频率压下来。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  /// 列表刷新间隔。日志是给人看的，秒级刷新足够。
  static const Duration _refreshInterval = Duration(seconds: 1);

  /// 上下键一次翻动的屏数。留出重叠部分，避免刚好切掉一整行。
  static const double _pageScrollScreens = 0.8;

  final ScrollController _scrollController = ScrollController();
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(
      _refreshInterval,
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// 按屏翻页。
  ///
  /// 日志条数会持续变化，按固定像素滚动在长列表上会显得很迟钝；
  /// 按屏幕高度翻页，遥控器上按几下就能走完一屏。
  void _scrollByScreens(double screens) {
    if (!_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    final target = (position.pixels + screens * position.viewportDimension)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _scrollByScreens(_pageScrollScreens);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _scrollByScreens(-_pageScrollScreens);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // 最新的日志排在最前面：打开页面就能看到刚刚发生了什么，不必先翻到最后
    final logs = Log.debugLogs.reversed.toList();
    return AppScaffold(
      child: Column(
        children: [
          AppStyle.vGap32,
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AppStyle.hGap48,
              HighlightButton(
                focusNode: AppFocusNode(),
                iconData: Icons.arrow_back,
                text: "返回",
                onTap: () {
                  Get.back();
                },
              ),
              AppStyle.hGap32,
              Text(
                "运行日志",
                style: AppStyle.titleStyleWhite.copyWith(
                  fontSize: 36.w,
                  fontWeight: FontWeight.bold,
                ),
              ),
              AppStyle.hGap24,
              Text(
                "保留最近 ${Log.debugLogs.length} 条，最新在上",
                style: AppStyle.subTextStyleWhite,
              ),
              const Spacer(),
            ],
          ),
          AppStyle.vGap24,
          Expanded(
            child: Focus(
              autofocus: true,
              onKeyEvent: _handleKeyEvent,
              child: logs.isEmpty
                  ? Center(
                      child: Text("暂无日志", style: AppStyle.textStyleWhite),
                    )
                  : ListView.separated(
                      controller: _scrollController,
                      padding: AppStyle.edgeInsetsA48,
                      itemCount: logs.length,
                      separatorBuilder: (context, index) => AppStyle.vGap8,
                      itemBuilder: (context, index) =>
                          _LogLine(log: logs[index]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单条日志。
class _LogLine extends StatelessWidget {
  /// 日志正文的字号。TV 是远距离观看，比列表页的正文再放大一档。
  static const double _fontSize = 22;

  final DebugLogModel log;
  const _LogLine({required this.log});

  @override
  Widget build(BuildContext context) {
    return Text(
      "${_formatTime(log.datetime)}  ${log.content}",
      style: TextStyle(
        fontSize: _fontSize.w,
        height: 1.3,
        color: log.color ?? Colors.white,
      ),
    );
  }

  /// 只保留时分秒。
  ///
  /// 排查关心的是「刚刚发生了什么」，日期既没有信息量，还会占掉行首的宽度。
  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, "0");
    final minute = time.minute.toString().padLeft(2, "0");
    final second = time.second.toString().padLeft(2, "0");
    return "$hour:$minute:$second";
  }
}
