> ### ⚠ 本项目不提供Release安装包，请自行编译后运行测试。


<p align="center">
    <img width="128" src="/assets/logo.png" alt="Simple Live logo">
</p>
<h2 align="center">Simple Live</h2>

<p align="center">
简简单单的看直播
</p>

![浅色模式](/assets/screenshot_light.jpg)

![深色模式](/assets/screenshot_dark.jpg)

## 支持直播平台：

- 虎牙直播

- 斗鱼直播

- 哔哩哔哩直播

- 抖音直播

## APP支持平台

- [x] Android
- [x] iOS
- [x] Windows `BETA`
- [x] MacOS `BETA`
- [x] Linux `BETA`
- [x] Android TV `BETA`

## 项目结构

- `simple_live_core` 项目核心库，实现获取各个网站的信息及弹幕。
- `simple_live_console` 基于simple_live_core的控制台程序。
- `simple_live_app` 基于核心库实现的Flutter APP客户端。
- `simple_live_tv_app` 基于核心库实现的Flutter Android TV客户端。

## 环境

Flutter : `3.38`

## 打包

产物统一放进 `pkg/`。

| 目标 | 命令（在对应子项目目录下执行） | 产物路径 |
| --- | --- | --- |
| iOS | `flutter build ipa --release --export-options-plist=ios/ExportOptions-debugging.plist` | `build/ios/ipa/simple_live_app.ipa` |
| macOS arm64 | `FLUTTER_XCODE_ARCHS=arm64 flutter build macos --release` | `build/macos/Build/Products/Release/Simple Live.app` |
| macOS x86_64 | `FLUTTER_XCODE_ARCHS=x86_64 flutter build macos --release` | 同上（同一路径，架构由构建参数决定） |
| Android 手机版（`simple_live_app`） | `flutter build apk --release --split-per-abi`（依赖 `android/key.properties`） | `build/app/outputs/flutter-apk/app-<abi>-release.apk` |
| Android TV（`simple_live_tv_app`） | `flutter build apk --release --split-per-abi` | `build/app/outputs/flutter-apk/app-<abi>-release.apk` |

macOS 的 dmg 用 `hdiutil` 打，与既有包结构一致（镜像里只有 app，无快捷方式）：

```bash
STAGE=$(mktemp -d)
ditto "build/macos/Build/Products/Release/Simple Live.app" "$STAGE/SimpleLive-arm64.app"
hdiutil create -volname "SimpleLive-arm64" -srcfolder "$STAGE" -ov -format UDZO \
  ../pkg/Simple_Live-<版本>-arm64.dmg
rm -rf "$STAGE"
```

注意事项：

- iOS 必须指定 `ios/ExportOptions-debugging.plist`：Xcode 27 的导出方式是 `debugging`（Development 签名，仅可装到已注册设备），而 `flutter build ipa --export-method` 不接受该值。
- macOS 用 `FLUTTER_XCODE_ARCHS=<arm64|x86_64>` 直接构建 thin 单架构，无需事后 `lipo` 瘦身与重签（构建参数由 Flutter 透传给 xcodebuild）。Flutter 的 `darwin-x64` 引擎 xcframework 本身含 arm64 + x86_64 两个 slice，在 Apple Silicon 上交叉构建 x86_64 无需额外配置。
- 首次构建若报 `media_kit_video/{macos,ios}/Headers/mpv/*.h: No such file`，是 pub cache 里 media_kit 的 podspec 在执行 `make` 下载依赖时静默失败（网络）。带代理按目标平台补生成后再构建：
  ```bash
  # macOS
  cd ~/.pub-cache/hosted/pub.dev/media_kit_libs_macos_video-1.1.4/macos && make
  cd ~/.pub-cache/hosted/pub.dev/media_kit_video-2.0.1 && make -C common/darwin HEADERS_DESTDIR="$PWD/macos/Headers"
  # iOS
  cd ~/.pub-cache/hosted/pub.dev/media_kit_libs_ios_video-1.1.4/ios && make
  cd ~/.pub-cache/hosted/pub.dev/media_kit_video-2.0.1 && make -C common/darwin HEADERS_DESTDIR="$PWD/ios/Headers"
  ```
- 两处 Podfile 的 `post_install` 已把各 pod 的部署目标对齐到项目声明值（iOS 15.0 / macOS 12.0）：Xcode 27 起低于该下限会直接构建失败，勿删。
- 各端签名：iOS 用 Development 证书（见上条，仅可装到已注册设备）；macOS 为 adhoc，首次打开需右键 → 打开；Android 手机版与 TV 分别用各自 `android/key.properties` 指向的 keystore，缺少该文件时 release 构建读取签名配置会直接失败。

## 参考及引用

[AllLive](https://github.com/xiaoyaocz/AllLive) `本项目的C#版，有兴趣可以看看`

[dart_tars_protocol](https://github.com/xiaoyaocz/dart_tars_protocol.git)

[wbt5/real-url](https://github.com/wbt5/real-url)

[lovelyyoshino/Bilibili-Live-API](https://github.com/lovelyyoshino/Bilibili-Live-API/blob/master/API.WebSocket.md)

[IsoaSFlus/danmaku](https://github.com/IsoaSFlus/danmaku)

[BacooTang/huya-danmu](https://github.com/BacooTang/huya-danmu)

[TarsCloud/Tars](https://github.com/TarsCloud/Tars)

[YunzhiYike/douyin-live](https://github.com/YunzhiYike/douyin-live)

[5ime/Tiktok_Signature](https://github.com/5ime/Tiktok_Signature)

## 声明

本项目的所有功能都是基于互联网上公开的资料开发，无任何破解、逆向工程等行为。

本项目仅用于学习交流编程技术，严禁将本项目用于商业目的。如有任何商业行为，均与本项目无关。

如果本项目存在侵犯您的合法权益的情况，请及时与开发者联系，开发者将会及时删除有关内容。

## Star History

<a href="https://www.star-history.com/#xiaoyaocz/dart_simple_live&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=xiaoyaocz/dart_simple_live&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=xiaoyaocz/dart_simple_live&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=xiaoyaocz/dart_simple_live&type=Date" />
 </picture>
</a>
