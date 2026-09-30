# Phase 1: Core UI + B站完整流程 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 在 Phase 0 播放验证基础上，搭建完整 UI 框架，实现 B站全流程（首页推荐 → 直播间播放+弹幕+聊天）

**前置条件：** Phase 0 已完成，`simple_live_desktop/` 项目存在且可编译

---

### 任务 1：添加 Vue Router + Naive UI

**文件：**
- 修改：`simple_live_desktop/frontend/package.json`
- 修改：`simple_live_desktop/frontend/src/main.js`
- 创建：`simple_live_desktop/frontend/src/router/index.js`

- [ ] **步骤 1：安装依赖**

```bash
cd /Users/zz/workspace/src/dart_simple_live/simple_live_desktop/frontend
pnpm add vue-router@4 naive-ui
```

- [ ] **步骤 2：创建路由配置**

`frontend/src/router/index.js`：
```javascript
import { createRouter, createWebHashHistory } from 'vue-router'

const routes = [
  { path: '/', name: 'home', component: () => import('../views/Home.vue') },
  { path: '/live/:roomId', name: 'live', component: () => import('../views/LiveRoom.vue'), props: true },
]

const router = createRouter({
  history: createWebHashHistory(),
  routes,
})

export default router
```

- [ ] **步骤 3：更新 main.js**

```javascript
import { createApp } from 'vue'
import naive from 'naive-ui'
import router from './router'
import App from './App.vue'

const app = createApp(App)
app.use(naive)
app.use(router)
app.mount('#app')
```

---

### 任务 2：首页推荐列表

**文件：**
- 创建：`frontend/src/views/Home.vue`
- 创建：`frontend/src/components/LiveCard.vue`

首页显示 B站推荐直播间列表：
- 顶部平台 Tab（B站/抖音/斗鱼/虎牙）
- 推荐直播间卡片网格（封面+标题+主播+在线）
- 翻页/加载更多

---

### 任务 3：直播间页面

**文件：**
- 创建：`frontend/src/views/LiveRoom.vue`
- 创建：`frontend/src/components/VideoPlayer.vue`
- 创建：`frontend/src/components/ChatPanel.vue`
- 创建：`frontend/src/components/DanmakuOverlay.vue`

直播间布局：
```
┌──────────────────────┬──────────────┐
│                      │  主播信息     │
│   视频播放器          │  聊天         │
│   + 弹幕叠加层        │  关注         │
│                      │  设置         │
└──────────────────────┴──────────────┘
```

---

### 任务 4：弹幕系统

**文件：**
- 修改：`backend/danmaku/bilibili.go`（新建）
- 修改：`frontend/src/components/DanmakuOverlay.vue`

Go 后端建立 WebSocket 连接，解析弹幕数据后通过 Wails Events 推送到前端。

---

### 任务 5：App.vue 框架 + 导航

- 全局导航栏（平台 Tab + 搜索框 + 菜单）
- 路由视图容器
- 深色主题
