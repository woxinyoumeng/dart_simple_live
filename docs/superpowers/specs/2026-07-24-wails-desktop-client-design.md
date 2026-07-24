# Wails 桌面直播客户端设计文档

## 概述

将现有的 Flutter 版 Simple Live 使用 Go + Wails 重写为轻量桌面客户端，目标为单文件可执行程序，方便分发。

## 技术栈

| 层 | 技术选型 |
|------|---------|
| 桌面壳 | **Wails v3** |
| 前端框架 | **Vue 3 + Vite** |
| 状态管理 | **Pinia** |
| 路由 | **Vue Router** |
| UI 组件库 | **Naive UI** |
| 视频播放 | **mpegts.js** (FLV) + **hls.js** (HLS) |
| 弹幕渲染 | **HTML5 Canvas** |
| 后端语言 | **Go** |
| 本地存储 | **bbolt** (嵌入式 KV 数据库) |
| WebSocket | **gorilla/websocket** |
| 编译产物 | 单文件 ~18MB |

## 项目结构

```
dart_simple_live_wails/
├── main.go                  # Wails 入口
├── app.go                   # Wails 绑定方法（前端调用的 API）
├── wails.json               # Wails 配置
├── go.mod
├── backend/
│   ├── platform/            # 各平台协议实现
│   │   ├── bilibili.go
│   │   ├── douyin.go
│   │   ├── douyu.go
│   │   └── huya.go
│   ├── danmaku/             # WebSocket 弹幕连接管理
│   ├── player/              # 视频流地址解析
│   ├── storage/             # bbolt 数据库操作
│   └── models/              # 共享数据结构
├── frontend/
│   ├── src/
│   │   ├── App.vue
│   │   ├── main.js
│   │   ├── router/
│   │   ├── stores/
│   │   ├── views/
│   │   │   ├── Home.vue
│   │   │   ├── Category.vue
│   │   │   ├── Search.vue
│   │   │   ├── LiveRoom.vue
│   │   │   ├── Follow.vue
│   │   │   └── Settings.vue
│   │   └── components/
│   │       ├── LiveCard.vue
│   │       ├── DanmakuCanvas.vue
│   │       ├── VideoPlayer.vue
│   │       └── ChatPanel.vue
│   ├── vite.config.js
│   └── package.json
└── build/
```

## 前端路由

| 路由 | 页面 | 说明 |
|------|------|------|
| `/` | 首页 | 站点 Tab 切换推荐列表 |
| `/category/:site` | 分类 | 按平台浏览分类 |
| `/search/:site` | 搜索 | 搜索房间/主播 |
| `/live/:site/:roomId` | 直播间 | 核心页面 |
| `/follow` | 关注 | 关注列表+标签管理 |
| `/settings` | 设置 | 应用设置 |

## Go 后端 API（Wails 绑定）

### 站点/房间
- `GetCategories(siteId) → []LiveCategory`
- `GetCategoryRooms(siteId, categoryId, page) → CategoryResult`
- `GetRecommendRooms(siteId, page) → CategoryResult`
- `SearchRooms(siteId, keyword, page) → SearchResult`
- `GetRoomDetail(siteId, roomId) → RoomDetail`
- `GetPlayUrls(siteId, roomId) → PlayUrls`
- `GetLiveStatus(siteId, roomId) → bool`

### 弹幕
- `ConnectDanmaku(siteId, roomId)` — 启动 WebSocket 连接
- `DisconnectDanmaku()` — 断开连接
- 后端通过 Wails Events 系统推送弹幕到前端

### 存储
- `GetFollowList() / AddFollow() / RemoveFollow()`
- `GetHistory() / ClearHistory()`
- `GetSettings() / SaveSettings()`

## 数据流

```
前端 (Vue)                     Go 后端
   │                              │
   │── GetRoomDetail() ──────────→│ 解析 API
   │←────── RoomDetail ──────────│
   │                              │
   │── ConnectDanmaku() ─────────→│ gorilla/websocket
   │← Events: "danmaku-message"  │ 推送到前端
   │                              │
   │── GetPlayUrls() ────────────→│ 解析播放地址
   │←── {urls: [flv, hls]} ─────│
   │                              │
   │ mpegts.js/hls.js 播放视频    │ （纯前端）
```

## 视频播放

FLV 流 → `mpegts.js` (WebCodecs decoder)
HLS 流 → `hls.js` (MediaSource Extensions)
MP4 → 原生 `<video>`

画质/线路切换：重新调用 `GetPlayUrls()` → 切换播放器源。

## 弹幕渲染

HTML5 Canvas 引擎：
- `requestAnimationFrame` 循环
- 弹道轨道管理（避免重叠）
- 弹幕速度/字体/透明度/颜色/配置
- 暂停/隐藏/关键词屏蔽
- 覆盖在 `<video>` 之上

## 存储设计

使用 bbolt，bucket 划分：
- `follows` — 关注用户列表
- `history` — 观看历史
- `settings` — 应用设置
- `tags` — 用户标签

## 阶段计划

### Phase 1 — 核心直播功能
项目脚手架、首页推荐、直播间（视频+弹幕+聊天）、B站完整支持、Douyin/Douyu/Huya 播放

### Phase 2 — 个人数据
关注列表、标签管理、观看历史、收藏

### Phase 3 — 内容发现
搜索、分类浏览、推荐

### Phase 4 — 完整功能
设置、同步、导入导出、SC 显示、弹幕屏蔽

## 编译产物

```
# macOS (arm64 + amd64)
wails build -platform darwin/universal
→ build/bin/SimpleLive.app (~18MB)

# Windows
wails build -platform windows/amd64
→ build/bin/SimpleLive.exe (~16MB)

# Linux
wails build -platform linux/amd64
→ build/bin/SimpleLive (~18MB)
```
