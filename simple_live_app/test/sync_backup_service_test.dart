// 同步数据备份（本地 zip 导出/导入）的行为用例
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_backup_service.dart';

/// path_provider 的方法通道名；测试环境没有真实插件实现，用临时目录顶替
const _pathProviderChannel = "plugins.flutter.io/path_provider";

const _settingsKey = "TestSettingKey";
const _settingsValue = "TestSettingValue";
const _testCookie = "test_cookie";

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final tmpDir = await Directory.systemTemp.createTemp("sl_backup_roundtrip");

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_pathProviderChannel),
      (call) async => tmpDir.path,
    );
    Hive.init(tmpDir.path);
    Hive.registerAdapter(FollowUserAdapter());
    Hive.registerAdapter(HistoryAdapter());
    Hive.registerAdapter(FollowUserTagAdapter());
    await Get.put(LocalStorageService()).init();
    await Get.put(DBService()).init();
    Get.put(AppSettingsController());
    Get.put(BiliBiliAccountService());
  });

  /// 写入一份已知数据
  Future<void> seed() async {
    await DBService.instance.followBox.clear();
    await DBService.instance.tagBox.clear();
    await DBService.instance.historyBox.clear();
    LocalStorageService.instance.shieldBox.clear();
    LocalStorageService.instance.settingsBox.clear();

    await DBService.instance.followBox.put(
      "bilibili_1",
      FollowUser(
        id: "bilibili_1",
        roomId: "1",
        siteId: "bilibili",
        userName: "测试用户A",
        face: "",
        addTime: DateTime(2026, 1, 1),
      ),
    );
    await DBService.instance.followBox.put(
      "bilibili_2",
      FollowUser(
        id: "bilibili_2",
        roomId: "2",
        siteId: "bilibili",
        userName: "测试用户B",
        face: "",
        addTime: DateTime(2026, 1, 2),
      ),
    );
    await DBService.instance.tagBox.put(
      "tag_1",
      FollowUserTag(id: "tag_1", tag: "游戏", userId: ["bilibili_1"]),
    );
    await DBService.instance.historyBox.put(
      "bilibili_1",
      History(
        id: "bilibili_1",
        roomId: "1",
        siteId: "bilibili",
        userName: "测试用户A",
        face: "",
        updateTime: DateTime(2026, 2, 1),
      ),
    );
    await DBService.instance.historyBox.put(
      "bilibili_2",
      History(
        id: "bilibili_2",
        roomId: "2",
        siteId: "bilibili",
        userName: "测试用户B",
        face: "",
        updateTime: DateTime(2026, 2, 2),
      ),
    );
    await LocalStorageService.instance.shieldBox.put("滚", "滚");
    await LocalStorageService.instance.shieldBox.put("广告", "广告");
    AppSettingsController.instance.shieldList.assignAll(["滚", "广告"]);
    await LocalStorageService.instance.settingsBox.put(_settingsKey, _settingsValue);
    BiliBiliAccountService.instance.setCookie(_testCookie);
  }

  group("SyncBackupService", () {
    test("导出包内包含 6 个约定文件名", () async {
      await seed();
      final bytes = await SyncBackupService().buildArchive();
      expect(bytes, isNotEmpty);

      final names = ZipDecoder()
          .decodeBytes(bytes)
          .files
          .where((f) => f.isFile)
          .map((f) => f.name)
          .toSet();

      expect(names, {
        SyncBackupService.followsFileName,
        SyncBackupService.tagsFileName,
        SyncBackupService.historiesFileName,
        SyncBackupService.blockedWordFileName,
        SyncBackupService.bilibiliAccountFileName,
        SyncBackupService.settingsFileName,
      });
    });

    test("导出→清空→导入可完整还原数据", () async {
      await seed();
      final bytes = await SyncBackupService().buildArchive();

      // 模拟换机：清空全部本地数据
      await DBService.instance.followBox.clear();
      await DBService.instance.tagBox.clear();
      await DBService.instance.historyBox.clear();
      await LocalStorageService.instance.shieldBox.clear();
      AppSettingsController.instance.shieldList.clear();
      await LocalStorageService.instance.settingsBox.clear();
      BiliBiliAccountService.instance.setCookie("");

      expect(DBService.instance.getFollowList(), isEmpty);
      expect(DBService.instance.getHistores(), isEmpty);
      expect(AppSettingsController.instance.shieldList, isEmpty);

      await SyncBackupService().restoreArchive(bytes);

      expect(DBService.instance.getFollowList().length, 2);
      expect(DBService.instance.getFollowTagList().length, 1);
      expect(DBService.instance.getFollowTagList().first.tag, "游戏");
      expect(DBService.instance.getHistores().length, 2);
      expect(AppSettingsController.instance.shieldList.toSet(), {"滚", "广告"});
      expect(
        LocalStorageService.instance.settingsBox.get(_settingsKey),
        _settingsValue,
      );
      expect(BiliBiliAccountService.instance.cookie, _testCookie);
    });

    test("导入的历史记录不会覆盖本地更新的记录", () async {
      await seed();
      final bytes = await SyncBackupService().buildArchive();

      // 本地把其中一条更新到更晚的时间
      final newer = DateTime(2026, 3, 1);
      await DBService.instance.historyBox.put(
        "bilibili_1",
        History(
          id: "bilibili_1",
          roomId: "1",
          siteId: "bilibili",
          userName: "本机较新",
          face: "",
          updateTime: newer,
        ),
      );

      await SyncBackupService().restoreArchive(bytes);

      expect(
        DBService.instance.getHistory("bilibili_1")!.userName,
        "本机较新",
        reason: "本地记录更新时间更晚时不应被备份包覆盖",
      );
    });

    test("恢复选项可关闭某一类数据的导入", () async {
      await seed();
      final bytes = await SyncBackupService().buildArchive();

      await DBService.instance.followBox.clear();
      await DBService.instance.tagBox.clear();
      await DBService.instance.historyBox.clear();

      await SyncBackupService().restoreArchive(
        bytes,
        restoreFollows: false,
      );

      expect(DBService.instance.getFollowList(), isEmpty,
          reason: "restoreFollows=false 时不应导入关注列表");
      expect(DBService.instance.getFollowTagList(), isEmpty);
      expect(DBService.instance.getHistores().length, 2,
          reason: "未关闭的类别仍应导入");
    });
  });
}
