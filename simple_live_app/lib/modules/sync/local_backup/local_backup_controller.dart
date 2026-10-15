import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/sync_backup_service.dart';

// 本地备份页面控制器：把同步数据导出为本地 zip 文件，或从 zip 文件恢复
class LocalBackupController extends BaseController {
  // 导出文件名的固定前缀
  static const String _fileNamePrefix = "SimpleLive_backup";

  // 导出文件名的固定后缀
  static const String _fileNameSuffix = ".zip";

  // 把同步数据导出为本地文件
  Future<void> exportToLocal() async {
    // 包内含哔哩哔哩账号 cookie 明文，导出前先让用户明确知晓风险
    var confirm = await Utils.showAlertDialog(
      "导出文件包含哔哩哔哩账号信息，请勿分享给他人。是否继续导出？",
      title: "导出同步数据",
    );
    if (!confirm) {
      return;
    }
    try {
      SmartDialog.showLoading(msg: "正在打包数据...");
      var bytes = await SyncBackupService().buildArchive();
      if (bytes.isEmpty) {
        SmartDialog.showToast("打包失败");
        return;
      }
      // 移动端与Web端由系统直接写入，桌面端需要自己写入
      var inlineSave = Platform.isAndroid || Platform.isIOS || kIsWeb;
      var fileName = _buildFileName();
      var path = await FilePicker.platform.saveFile(
        dialogTitle: "导出同步数据",
        type: FileType.custom,
        allowedExtensions: ['zip'],
        fileName: fileName,
        bytes: inlineSave ? bytes : null,
      );
      if (path == null && !kIsWeb) {
        SmartDialog.showToast("保存取消");
        return;
      }
      if (!inlineSave && path != null) {
        await File(path).writeAsBytes(bytes);
      }
      // 用户反馈“导出没反应”时靠这条日志定位
      Log.i('导出同步数据成功：$fileName，${bytes.length} 字节');
      SmartDialog.showToast("导出成功");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导出失败：$e");
    } finally {
      SmartDialog.dismiss();
    }
  }

  // 从本地文件恢复同步数据
  Future<void> importFromLocal() async {
    var loading = false;
    try {
      var result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (result == null) {
        return;
      }
      // 导入会覆盖本机数据，需要用户确认
      var confirm = await Utils.showAlertDialog(
        "导入会覆盖本机数据，是否继续？",
        title: "本地导入",
      );
      if (!confirm) {
        return;
      }
      SmartDialog.showLoading(msg: "正在恢复数据...");
      loading = true;
      var filePath = result.files.single.path!;
      var bytes = await File(filePath).readAsBytes();
      await SyncBackupService().restoreArchive(bytes);
      // 移动端 file_picker 会把选中文件复制进应用缓存目录，导入后清掉这份含账号信息的副本；
      // 桌面端拿到的是用户原始文件，绝不能在缓存目录判断之外删除
      try {
        var cacheDir = (await getTemporaryDirectory()).path;
        if (filePath.startsWith("$cacheDir${Platform.pathSeparator}")) {
          await File(filePath).delete();
        }
      } catch (e) {
        // 清理失败只记日志，不能影响已经成功的导入
        Log.logPrint(e);
      }
      // 用户反馈“导入没反应”时靠这条日志定位
      Log.i('导入同步数据成功：文件 ${bytes.length} 字节');
      SmartDialog.showToast("导入完成");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导入失败：$e");
    } finally {
      if (loading) {
        SmartDialog.dismiss();
      }
    }
  }

  // 生成带时间戳的导出文件名，例如 SimpleLive_backup_20261015_103000.zip
  String _buildFileName() {
    var now = DateTime.now();
    var date = "${now.year}${_twoDigits(now.month)}${_twoDigits(now.day)}";
    var time =
        "${_twoDigits(now.hour)}${_twoDigits(now.minute)}${_twoDigits(now.second)}";
    return "${_fileNamePrefix}_${date}_$time$_fileNameSuffix";
  }

  // 数字补齐两位，例如 3 补为 03
  String _twoDigits(int value) {
    return value.toString().padLeft(2, '0');
  }
}
