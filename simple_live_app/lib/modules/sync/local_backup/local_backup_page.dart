import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/sync/local_backup/local_backup_controller.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';

// 本地备份页面：导出同步数据到本地文件，或从本地文件恢复
class LocalBackupPage extends GetView<LocalBackupController> {
  const LocalBackupPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("本地备份"),
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          SettingsCard(
            child: Column(
              children: [
                ListTile(
                  title: const Text("导出到本地"),
                  leading: const Icon(Remix.save_3_line),
                  subtitle: const Text(
                      "把关注、标签、观看记录、屏蔽词、账号与应用设置打包为 zip 文件"),
                  onTap: controller.exportToLocal,
                ),
                AppStyle.divider,
                ListTile(
                  title: const Text("从本地导入"),
                  leading: const Icon(Remix.upload_2_line),
                  subtitle: const Text("从导出的 zip 文件恢复数据，会覆盖本机数据"),
                  onTap: controller.importFromLocal,
                ),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 12),
            child: Text(
              "导出文件包含哔哩哔哩账号信息，请妥善保管。",
              style: Get.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
