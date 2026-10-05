# TV 端黑屏与关注列表封面修复 - 2026-10-05

设备：华为智慧屏 V5 / HarmonyOS 4.3.0.252

## 一、直播只有声音没有画面

### 症状

- 播放时能听到声音，视频区域全黑，播控栏、弹幕等 UI 正常
- 用户反馈"以前正常、最近才黑"。与代码事实对照，最合理的解释是：兼容模式一直
  是默认开启的，旧版 Flutter 尚带 Skia 后端时 `mediacodec_embed` 这条路径可用，
  升级到只剩 Impeller 的 3.38 后同一条路径失效——用户没动过任何设置，变的是
  渲染后端（该推断未做版本对照验证）

### 根因

两条渲染路径在这台设备上都不通，叠在一起：

1. **兼容模式默认开启**。`AppSettingsController` 里 `kPlayerCompatMode` 的默认值是
   `true`，即开箱状态就是 `vo=mediacodec_embed` + `hwdec=mediacodec`——由 MediaCodec
   直接把画面写进 Flutter 的 Surface。
2. **Flutter 3.38 在 Android 上只剩 Impeller**。本地反编译 3.38.10 的
   `libflutter.so` 确认：只有 `Using the Impeller rendering backend (...)`，
   没有 `Using the Skia rendering backend`，没有 Skia 可回退。
3. 插件渲染 Surface 的路径在华为这类非主流 GPU 驱动上会失败（对照
   flutter/flutter#187419，同一形状的问题至今 OPEN）。而 `media_kit` 走的是
   `FlutterRenderer.createSurfaceProducer()` → `ImageReaderSurfaceProducer`
   （`import 'package:flutter/services.dart'` 无关，见下方证据），正好落在这条路上。

### 修复

`android/app/src/main/AndroidManifest.xml` 增加：

```xml
<meta-data
    android:name="io.flutter.embedding.android.ImpellerBackend"
    android:value="opengles" />
```

取值依据来自引擎自身：`libflutter.so` 里 `--impeller-backend` 的说明是
"Requests a particular Impeller backend on platforms that support multiple
backends. (ex `opengles` or `vulkan`)"，key 名来自 `FlutterLoader.class` 的常量池。

设备侧配置：**兼容模式保持「关」**（实测只有关掉它才出画面）。

### 未分离的变量

`ImpellerBackend=opengles` 与「关闭兼容模式」是在同一次构建里同时生效的，
两者各自贡献多少尚未分离。若要彻底确认，需出一个撤掉 manifest 该项、保持
兼容模式关闭的对照包。当前配置可用，暂保留。

## 二、关注列表没有封面缩略图

### 症状

直播中的房间仍是圆形头像卡片 + 右上角绿色"直播中"，没有 16:9 封面卡片。

### 根因

**关注列表在代码里有两份实现**，只改一份等于没改：

- `modules/home/home_page.dart` —— 首页内嵌的"我的关注"（用户实际看到的）
- `modules/follow_user/follow_user_page.dart` —— 通过"管理"进入的独立关注页

TV 首页顶部标题是 "Simple Live TV"，独立关注页顶部是"返回 / 我的关注 / 刷新"，
截图里是前者。

### 修复

抽出共用组件 `FollowUserListItem`（`widgets/card/follow_user_card.dart`）：

```dart
Obx(() => item.liveStatus.value == 2
    ? FollowUserCard(item: item)   // 16:9 封面
    : AnchorCard(...));            // 圆形头像
```

两处列表都改用该组件，结构上消除"只改一边"的可能。
配套测试 `test/follow_user_list_item_test.dart` 覆盖四种状态组合。

### 附带修复

`FollowUserService.updateLiveStatus` 原本把"状态查询"和"详情查询"放在同一个
try 里，详情接口失败会把已查到的 `liveStatus=2` 重置为 0——直播中的房间会
退回未开播卡片。现已拆成两段独立容错：状态先落盘，详情只影响封面与开播时长。

## 三、无 adb 时的排查手段

新增应用内「运行日志」页（设置 → 关于 → 运行日志），`Log` 保留最近 200 条
日志到内存，上下键翻页。播放后会写入一条诊断：

```text
播放诊断：vo=gpu wid=12345 编码=h264 hwdec=mediacodec 分辨率=1920x1080
```

`vo` 取不到有效值 = 视频没接进显示层；`vo` 正常仍黑屏 = 渲染层问题。

## 四、构建注意

环境默认 `JAVA_HOME` 指向 JDK 27，Kotlin 编译器解析不了 `java.version`，
Gradle 会抛出极其难懂的 `What went wrong: 27`。构建必须用 JDK 17：

```bash
export JAVA_HOME=/Users/zz/.local/share/mise/installs/java/17.0.2
flutter build apk --release --split-per-abi
```

产物按 `Simple_Live_TV-<版本>-android-<abi>.apk` 命名放入仓库根目录 `pkg/`。
