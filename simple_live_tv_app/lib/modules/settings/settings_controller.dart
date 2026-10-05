import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';

class SettingsController extends BaseController
    with GetTickerProviderStateMixin {
  late TabController tabController;
  var tabIndex = 0.obs;

  SettingsController() {
    tabController = TabController(length: 5, vsync: this);
    tabController.animation?.addListener(() {
      var currentIndex = (tabController.animation?.value ?? 0).round();
      if (tabIndex.value == currentIndex) {
        return;
      }
      tabIndex.value = currentIndex;
      if (tabIndex.value == 0) {
        hardwareDecodeFocusNode.requestFocus();
      }
      if (tabIndex.value == 1) {
        danmakuFoucsNode.requestFocus();
      }
      if (tabIndex.value == 2) {
        autoUpdateFollowEnableFocusNode.requestFocus();
      }
      if (tabIndex.value == 3) {
        bilibiliFoucsNode.requestFocus();
      }
      if (tabIndex.value == 4) {
        versionFocusNode.requestFocus();
      }
    });
  }
  var hardwareDecodeFocusNode = AppFocusNode()..isFoucsed.value = true;
  var compatibleModeFocusNode = AppFocusNode();
  var scaleFoucsNode = AppFocusNode();
  var defaultQualityFocusNode = AppFocusNode();
  var customPlayerOutputFocusNode = AppFocusNode();
  var videoOutputDriverFocusNode = AppFocusNode();
  var videoHardwareDecoderFocusNode = AppFocusNode();

  /// 视频输出驱动（--vo）。
  ///
  /// TV 端运行在 Android 上，只列出 Android 可用的驱动：桌面平台专有的
  /// xv/vdpau/direct3d 等在这里选择了也不生效，只会徒增遥控器操作成本。
  var videoOutputDrivers = {
    "gpu": "gpu",
    "gpu-next": "gpu-next",
    "mediacodec_embed": "mediacodec_embed",
    "null": "null（不渲染画面）",
  };

  /// 硬件解码器（--hwdec），同样只保留 Android 可用的取值。
  var videoHardwareDecoders = {
    "no": "no（纯软解）",
    "auto": "auto",
    "auto-safe": "auto-safe",
    "yes": "yes",
    "mediacodec": "mediacodec",
    "mediacodec-copy": "mediacodec-copy",
  };
  var danmakuFoucsNode = AppFocusNode();
  var danmakuSizeFoucsNode = AppFocusNode();
  var danmakuSpeedFoucsNode = AppFocusNode();
  var danmakuAreaFoucsNode = AppFocusNode();
  var danmakuOpacityFoucsNode = AppFocusNode();
  var danmakuStorkeFoucsNode = AppFocusNode();

  var autoUpdateFollowEnableFocusNode = AppFocusNode();
  var autoUpdateFollowDurationFocusNode = AppFocusNode();
  var updateFollowThreadFocusNode = AppFocusNode();

  var bilibiliFoucsNode = AppFocusNode();
  var versionFocusNode = AppFocusNode();
  var cacheFocusNode = AppFocusNode();
  var logFocusNode = AppFocusNode();
  void bilibiliTap() async {
    if (BiliBiliAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出哔哩哔哩账号吗？", title: "退出登录");
      if (result) {
        BiliBiliAccountService.instance.logout();
      }
    } else {
      AppNavigator.toBiliBiliLogin();
    }
  }

}
