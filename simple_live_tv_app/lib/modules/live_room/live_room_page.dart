import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_tv_app/modules/live_room/player/player_controls.dart';

/// 恢复提示条在画面上的位置。
///
/// 顶部标题栏与底部播控栏的高度随屏幕比例变化，用相对位置把提示条放在画面
/// 中部偏上，既不遮挡整屏，也不会压住任一条播控栏。
const Alignment _recoverHintAlignment = Alignment(0, -0.6);

class LiveRoomPage extends GetView<LiveRoomController> {
  const LiveRoomPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          //双击返回键退出
          if (controller.doubleClickExit) {
            controller.doubleClickTimer?.cancel();
            Get.back();
            return;
          }
          controller.doubleClickExit = true;
          SmartDialog.showToast("再按一次退出播放器");
          controller.doubleClickTimer = Timer(const Duration(seconds: 2), () {
            controller.doubleClickExit = false;
            controller.doubleClickTimer!.cancel();
          });
        }
      },
      child: KeyboardListener(
        focusNode: controller.focusNode,
        autofocus: true,
        onKeyEvent: onKeyEvent,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Obx(
            () => buildMediaPlayer(),
          ),
        ),
      ),
    );
  }

  void onKeyEvent(KeyEvent key) {
    if (key is KeyUpEvent) {
      return;
    }
    Log.logPrint(key);

    // if (key.logicalKey == LogicalKeyboardKey.escape ||
    //     key.logicalKey == LogicalKeyboardKey.backspace ||
    //     key.logicalKey == LogicalKeyboardKey.goBack) {
    //   // Get.back();
    //   return;
    // }
    // 点击OK、Enter、Select键时显示/隐藏控制器
    if (key.logicalKey == LogicalKeyboardKey.select ||
        key.logicalKey == LogicalKeyboardKey.enter ||
        key.logicalKey == LogicalKeyboardKey.space) {
      if (!controller.showControlsState.value) {
        controller.showControls();
      } else {
        controller.hideControls();
      }
      return;
    }

    // 点击Menu打开/关闭设置
    if (key.logicalKey == LogicalKeyboardKey.keyM ||
        key.logicalKey == LogicalKeyboardKey.contextMenu ||
        key.logicalKey == LogicalKeyboardKey.arrowRight) {
      showPlayerSettings(controller);
      return;
    }

    // 点击左键显示关注用户
    if (key.logicalKey == LogicalKeyboardKey.arrowLeft) {
      showFollowUser(controller);
      return;
    }

    // // 点击右键关注/取消关注
    // if (key.logicalKey == LogicalKeyboardKey.arrowRight) {
    //   if (controller.followed.value) {
    //     controller.removeFollowUser();
    //   } else {
    //     controller.followUser();
    //   }

    //   return;
    // }

    // 点击上键切换上一个直播
    if (key.logicalKey == LogicalKeyboardKey.arrowUp) {
      controller.prevChannel();
      return;
    }

    // 点击下键切换下一个直播
    if (key.logicalKey == LogicalKeyboardKey.arrowDown) {
      controller.nextChannel();
      return;
    }
  }

  Widget buildMediaPlayer() {
    var boxFit = BoxFit.contain;
    double? aspectRatio;
    if (AppSettingsController.instance.scaleMode.value == 0) {
      boxFit = BoxFit.contain;
    } else if (AppSettingsController.instance.scaleMode.value == 1) {
      boxFit = BoxFit.fill;
    } else if (AppSettingsController.instance.scaleMode.value == 2) {
      boxFit = BoxFit.cover;
    } else if (AppSettingsController.instance.scaleMode.value == 3) {
      boxFit = BoxFit.contain;
      aspectRatio = 16 / 9;
    } else if (AppSettingsController.instance.scaleMode.value == 4) {
      boxFit = BoxFit.contain;
      aspectRatio = 4 / 3;
    }
    return Stack(
      children: [
        Video(
          key: controller.globalPlayerKey,
          controller: controller.videoController,
          pauseUponEnteringBackgroundMode:
              AppSettingsController.instance.playerAutoPause.value,
          resumeUponEnteringForegroundMode:
              AppSettingsController.instance.playerAutoPause.value,
          controls: (state) {
            return playerControls(state, controller);
          },
          aspectRatio: aspectRatio,
          fit: boxFit,
        ),
        Obx(
          () => Visibility(
            visible:
                !controller.liveStatus.value && !controller.pageLoadding.value,
            child: Center(
              child: Text(
                "未开播",
                style: AppStyle.textStyleWhite,
              ),
            ),
          ),
        ),
        buildRecoverHint(),
      ],
    );
  }

  /// 播放恢复期间的提示。
  ///
  /// 恢复链会把断流原因写进 errorMsg，但直播页此前没有渲染它，用户在恢复
  /// 期间只能看到黑屏；重新打开播放时 errorMsg 会被清空，提示随恢复自动
  /// 消失，所以这里只按「在直播且 errorMsg 非空」显示。
  ///
  /// 提示不接收点击：它盖在画面上，若吞掉遥控器确认键，用户就点不出播控栏。
  Widget buildRecoverHint() {
    return Obx(() {
      final message = controller.errorMsg.value;
      if (!controller.liveStatus.value || message.isEmpty) {
        return const SizedBox.shrink();
      }
      return Align(
        alignment: _recoverHintAlignment,
        child: IgnorePointer(child: _RecoverHintBar(message: message)),
      );
    });
  }
}

/// 播放恢复期间的轻量提示条。
///
/// 恢复期间画面可能是黑的，白字需要自带的半透明底色才读得清；提示条只包住
/// 文案本身，不铺满整屏。
class _RecoverHintBar extends StatelessWidget {
  const _RecoverHintBar({required this.message});

  /// 恢复链写下的提示文案。
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: AppStyle.edgeInsetsA8,
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: AppStyle.radius24,
      ),
      child: Text(message, style: AppStyle.textStyleWhite),
    );
  }
}
