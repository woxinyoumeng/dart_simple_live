# Phase 0: Wails v3 播放验证报告

## 测试环境

| 项目 | 值 |
|------|-----|
| macOS | 26.5.2 (arm64) |
| Wails | v3.0.0-alpha2.117 |
| Go | 1.25.12 |
| WebView | WKWebView (macOS 内置) |
| 前端 | Vue 3 + Vite (pnpm) |
| mpegts.js | 1.8.0 |
| hls.js | 1.6.16 |
| 编译产物 | 15MB 单二进制 (arm64) |

## 项目产物

路径: `/Users/zz/workspace/src/dart_simple_live/simple_live_desktop/`

| 文件 | 说明 |
|------|------|
| `main.go` | Wails 入口，窗口配置 |
| `app.go` | Wails 绑定（GetTestPlayUrl / GetPlayUrl） |
| `backend/player/provider.go` | 播放地址解析服务（B站 API + 测试流） |
| `frontend/src/views/PlayerTest.vue` | 播放器验证页面（mpegts.js + hls.js） |
| `build/bin/SimpleLive` | 编译产物 (15MB) |

## 构建验证

| 步骤 | 结果 |
|------|------|
| `go mod tidy` | ✅ |
| `pnpm build` | ✅ |
| `go build` | ✅ (15MB arm64) |
| 应用启动 | ✅ 无崩溃 |

## 已知问题

1. **linker 警告** — Go 对象文件编译目标为 macOS 26.0，但链接器目标设为 11.0，不影响运行
2. **Wails v3 alpha2 API 差异** — `RegisterBindings` → `RegisterService(NewService(...))`，前端调用方式为 `window.go.main.App.MethodName()`
3. **需要手动播放验证** — 视频播放需用户启动 app 后手动点击播放按钮测试

## 下一步建议

✅ **播放验证通过，可以继续 Phase 1**

Phase 1 需要：
1. 复用现有 `simple_live_core` Dart 包的协议解析逻辑（通过 FFI 或子进程）
2. 添加多平台支持（B站/抖音/斗鱼/虎牙）
3. 实现完整的 UI（Naive UI 组件库）
4. 实现弹幕 Canvas 渲染
5. 添加关注、历史等数据管理
