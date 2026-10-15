import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils/archive.dart';
import 'package:simple_live_app/app/utils/document.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

// 同步数据打包与恢复服务
//
// 需要同步的数据共 6 类：关注用户、自定义标签、观看记录、弹幕屏蔽词、
// 哔哩哔哩账号 cookie、应用设置。
// 云端（WebDAV）同步与本地备份导出导入共用本类，保证两种方式的数据结构一致。
class SyncBackupService {
  // 以下文件名与 WebDAV 备份文件名保持一致，保证本地包与云端包互通
  // 关注用户数据文件名
  static const String followsFileName = 'SimpleLive_follows.json';
  // 用户自定义标签数据文件名
  static const String tagsFileName = 'SimpleLive_Tags.json';
  // 观看记录数据文件名
  static const String historiesFileName = 'SimpleLive_histories.json';
  // 弹幕屏蔽词数据文件名
  static const String blockedWordFileName = 'SimpleLive_blocked_word.json';
  // 哔哩哔哩账号数据文件名
  static const String bilibiliAccountFileName =
      'SimpleLive_bilibili_account.json';
  // 应用设置数据文件名
  static const String settingsFileName = 'SimpleLive_Settings.json';

  // 打包时使用的临时目录名
  static const String _backupDirName = 'backup';

  // 把需要同步的数据打包为 zip 字节
  Future<Uint8List> buildArchive() async {
    final archive = Archive();
    List<int> zipBytes = [];
    // 获取本地备份路径
    var dir = (await getApplicationSupportDirectory()).path;
    var profile = Directory(join(dir, _backupDirName));
    if (!profile.existsSync()) {
      profile.createSync();
    }
    try {
      // archive.add(filepath, data_map) 会导致文件损坏，所以先落盘再打包
      await _writeFollowsJson(profile);
      await _writeTagsJson(profile);
      await _writeHistoriesJson(profile);
      await _writeBlockedWordJson(profile);
      await _writeBilibiliAccountJson(profile);
      await _writeSettingsJson(profile);

      // 遍历profile路径下的所有文件压缩
      await archive.addDirectoryToArchive(profile.path, profile.path);
      final zipEncoder = ZipEncoder();
      zipBytes = zipEncoder.encode(archive);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("备份失败：$e");
    } finally {
      // 临时目录里落着哔哩哔哩账号 cookie 明文，打包成功与否都必须清理
      profile.clearSync();
    }
    return Uint8List.fromList(zipBytes);
  }

  // 从 zip 字节恢复数据
  //
  // [restoreFollows] 是否恢复关注用户与自定义标签（标签依赖关注，需同时恢复）
  // [restoreHistories] 是否恢复观看记录
  // [restoreBlockedWord] 是否恢复弹幕屏蔽词
  // [restoreBilibiliAccount] 是否恢复哔哩哔哩账号
  // 应用设置始终恢复，与 WebDAV 同步保持一致
  Future<void> restoreArchive(
    Uint8List bytes, {
    bool restoreFollows = true,
    bool restoreHistories = true,
    bool restoreBlockedWord = true,
    bool restoreBilibiliAccount = true,
  }) async {
    final archive = await Isolate.run<Archive>(() {
      final zipDecoder = ZipDecoder();
      return zipDecoder.decodeBytes(bytes);
    });
    var matchedCount = 0;
    for (ArchiveFile file in archive) {
      var matched = await _restoreFile(
        file,
        restoreFollows: restoreFollows,
        restoreHistories: restoreHistories,
        restoreBlockedWord: restoreBlockedWord,
        restoreBilibiliAccount: restoreBilibiliAccount,
      );
      if (matched) {
        matchedCount++;
      }
    }
    // 一个已知文件名都没匹配上，说明这不是本应用导出的包，不能当成功
    if (matchedCount == 0) {
      throw Exception("不是有效的备份文件");
    }
  }

  // 写入关注用户数据
  Future<void> _writeFollowsJson(Directory profile) async {
    var userFollowList = DBService.instance.getFollowList();
    var dataFollowsMap = {
      'data': userFollowList.map((e) => e.toJson()).toList()
    };
    final userFollowJsonFile = File(join(profile.path, followsFileName));
    await userFollowJsonFile.writeAsString(jsonEncode(dataFollowsMap));
  }

  // 写入用户自定义标签数据
  Future<void> _writeTagsJson(Directory profile) async {
    var userTagsList = DBService.instance.getFollowTagList();
    var dataTagsMap = {'data': userTagsList.map((e) => e.toJson()).toList()};
    var userTagsJsonFile = File(join(profile.path, tagsFileName));
    await userTagsJsonFile.writeAsString(jsonEncode(dataTagsMap));
  }

  // 写入观看记录数据
  Future<void> _writeHistoriesJson(Directory profile) async {
    var userHistoriesList = DBService.instance.getHistores();
    var dataHistoriesMap = {
      'data': userHistoriesList.map((e) => e.toJson()).toList()
    };
    final userHistoriesJsonFile =
        File(join(profile.path, historiesFileName));
    await userHistoriesJsonFile.writeAsString(jsonEncode(dataHistoriesMap));
  }

  // 写入弹幕屏蔽词数据
  Future<void> _writeBlockedWordJson(Directory profile) async {
    var userShieldList = AppSettingsController.instance.shieldList;
    var dataShieldListMap = {'data': userShieldList.toList()};
    final userBlockedWordJsonFile =
        File(join(profile.path, blockedWordFileName));
    await userBlockedWordJsonFile.writeAsString(jsonEncode(dataShieldListMap));
  }

  // 写入哔哩哔哩账号数据
  Future<void> _writeBilibiliAccountJson(Directory profile) async {
    var userBiliAccountCookieMap = {
      'data': {'cookie': BiliBiliAccountService.instance.cookie}
    };
    final bilibiliAccountJsonFile =
        File(join(profile.path, bilibiliAccountFileName));
    await bilibiliAccountJsonFile
        .writeAsString(jsonEncode(userBiliAccountCookieMap));
  }

  // 写入应用设置数据
  Future<void> _writeSettingsJson(Directory profile) async {
    var settingList = LocalStorageService.instance.settingsBox.toMap();
    var dataSettingListMap = {'data': settingList};
    final settingJsonFile = File(join(profile.path, settingsFileName));
    await settingJsonFile.writeAsString(jsonEncode(dataSettingListMap));
  }

  // 按文件名恢复单个备份文件中的数据
  //
  // 返回 true 表示包内文件命中约定的备份文件名（是否真正写入数据还要看对应开关），
  // 调用方据此判断整个包是否为有效备份
  Future<bool> _restoreFile(
    ArchiveFile file, {
    required bool restoreFollows,
    required bool restoreHistories,
    required bool restoreBlockedWord,
    required bool restoreBilibiliAccount,
  }) async {
    if (!file.isFile || !file.name.endsWith('.json')) {
      Log.i('不是正确的文件名');
      return false;
    }
    // 先只按文件名判断有效性，开关关闭的文件也属于合法备份内容
    var isKnownName = file.name == followsFileName ||
        file.name == tagsFileName ||
        file.name == historiesFileName ||
        file.name == blockedWordFileName ||
        file.name == bilibiliAccountFileName ||
        file.name == settingsFileName;
    if (!isKnownName) {
      Log.i('不是正确的文件名');
      return false;
    }
    var jsonString = utf8.decode(file.content);
    var jsonData = json.decode(jsonString)['data'];
    if (file.name == followsFileName && restoreFollows) {
      await _restoreFollows(jsonData);
    } else if (file.name == historiesFileName && restoreHistories) {
      await _restoreHistories(jsonData);
    } else if (file.name == blockedWordFileName && restoreBlockedWord) {
      await _restoreBlockedWord(jsonData);
    } else if (file.name == bilibiliAccountFileName &&
        restoreBilibiliAccount) {
      await _restoreBilibiliAccount(jsonData);
    } else if (file.name == settingsFileName) {
      await _restoreSettings(jsonData);
    } else if (file.name == tagsFileName && restoreFollows) {
      await _restoreTags(jsonData);
    }
    return true;
  }

  // 恢复关注用户列表
  Future<void> _restoreFollows(dynamic jsonData) async {
    // 当前云优先
    try {
      // 清空本地关注列表
      await DBService.instance.followBox.clear();
      for (var item in jsonData) {
        var user = FollowUser.fromJson(item);
        await DBService.instance.followBox.put(user.id, user);
      }
      Log.i('已同步关注用户列表');
    } catch (e) {
      Log.e('同步关注用户列表失败: $e', StackTrace.current);
    }
  }

  // 恢复观看记录
  Future<void> _restoreHistories(dynamic jsonData) async {
    try {
      for (var item in jsonData) {
        var history = History.fromJson(item);
        if (DBService.instance.historyBox.containsKey(history.id)) {
          var old = DBService.instance.historyBox.get(history.id);
          //如果本地的更新时间比较新，就不更新
          if (old!.updateTime.isAfter(history.updateTime)) {
            continue;
          }
        }
        await DBService.instance.addOrUpdateHistory(history);
      }
      Log.i('已同步用户观看历史记录');
    } catch (e) {
      Log.e('同步用户观看历史记录失败: $e', StackTrace.current);
    }
  }

  // 恢复弹幕屏蔽词
  Future<void> _restoreBlockedWord(dynamic jsonData) async {
    try {
      for (var keyword in jsonData) {
        AppSettingsController.instance.addShieldList(keyword.trim());
      }
      Log.i('已同步用户屏蔽词');
    } catch (e) {
      Log.e('同步用户屏蔽词失败:$e', StackTrace.current);
    }
  }

  // 恢复哔哩哔哩账号
  Future<void> _restoreBilibiliAccount(dynamic jsonData) async {
    try {
      var cookie = jsonData['cookie'];
      BiliBiliAccountService.instance.setCookie(cookie);
      BiliBiliAccountService.instance.loadUserInfo();
      Log.i('已同步哔哩哔哩账号');
    } catch (e) {
      Log.e('同步哔哩哔哩账号失败：$e', StackTrace.current);
    }
  }

  // 恢复应用设置
  Future<void> _restoreSettings(dynamic jsonData) async {
    try {
      await LocalStorageService.instance.settingsBox.clear();
      LocalStorageService.instance.settingsBox.putAll(jsonData);
      Log.i('已同步用户设置');
    } catch (e) {
      Log.e("同步用户设置失败：$e", StackTrace.current);
    }
  }

  // 恢复用户自定义标签
  Future<void> _restoreTags(dynamic jsonData) async {
    try {
      // 标签功能和关注具有依赖关系，必须同时同步
      // 清空本地标签列表
      await DBService.instance.tagBox.clear();
      for (var item in jsonData) {
        var tag = FollowUserTag.fromJson(item);
        await DBService.instance.tagBox.put(tag.id, tag);
        // 插入之后验证
        var insertedTag = DBService.instance.tagBox.get(tag.id);
        Log.i('Inserted tag: ${insertedTag?.tag}');
      }
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      Log.i('已同步用户自定义标签');
    } catch (e) {
      Log.e('同步用户自定义标签失败:$e', StackTrace.current);
    }
  }
}
