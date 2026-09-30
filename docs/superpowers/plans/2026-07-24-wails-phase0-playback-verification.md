# Phase 0: 播放验证 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 搭建 Wails v3 + Vue 3 + Vite 最小项目，验证 mpegts.js/hls.js 在 Wails WebView 中播放直播流的可行性。

**架构：**
- 新建 `simple_live_desktop/` 目录作为 Wails 项目根目录
- Go 后端提供一个简单的 API 返回测试用的 FLV/HLS 播放地址
- 前端 Vue 3 使用 mpegts.js 播放 FLV 流，验证视频渲染、控制栏交互
- 验证完成后产出可行性报告

**技术栈：** Go 1.21+, Wails v3, Vue 3 + Vite, mpegts.js, hls.js

**前置条件：**
- Go 已安装（go 1.21+）
- Node.js 18+（已有 v22）
- Xcode Command Line Tools（已有）

---

### 任务 1：初始化 Wails v3 项目

**文件：**
- 创建：`simple_live_desktop/main.go`
- 创建：`simple_live_desktop/app.go`
- 创建：`simple_live_desktop/wails.json`
- 创建：`simple_live_desktop/go.mod`

- [ ] **步骤 1：安装 Wails CLI**

```bash
go install github.com/wailsapp/wails/v3/cmd/wails@latest
```

预期：`wails` 命令可用

- [ ] **步骤 2：初始化项目结构**

手动创建项目文件，避免使用 `wails init`（v3 的 init 模板可能不稳定）。

创建 `simple_live_desktop/go.mod`：

```go
module simple_live_desktop

go 1.21
```

创建 `simple_live_desktop/wails.json`：

```json
{
  "$schema": "https://wails.io/schemas/config.v3.json",
  "name": "Simple Live",
  "outputfilename": "SimpleLive",
  "frontend:install": "npm install",
  "frontend:build": "npm run build",
  "frontend:dev:watcher": "npm run dev",
  "frontend:dev:serverUrl": "http://localhost:5173",
  "author": {
    "name": "zheng zhang",
    "email": ""
  }
}
```

- [ ] **步骤 3：创建 Go 主入口**

`simple_live_desktop/main.go`：

```go
package main

import (
	"context"
	"embed"
	"fmt"
	"log"

	"github.com/wailsapp/wails/v3/pkg/application"
)

//go:embed frontend/dist/*
var assets embed.FS

func main() {
	app := application.New(application.Options{
		Name:        "Simple Live",
		Description: "直播观看客户端",
		Mac: application.MacOptions{
			ActivationPolicy: application.ActivationPolicyRegular,
		},
		Assets: application.AssetOptions{
			Handler: application.BundledAssetFileServer(assets),
		},
	})

	app.NewWebviewWindow(application.WebviewWindowOptions{
		Title:  "Simple Live",
		Width:  1280,
		Height: 800,
		Mac: application.MacWindowOptions{
			TitleBar:          application.TitleBarDefault,
			Appearance:        application.NSAppearanceNameDarkAqua,
			InvisibleTitleBar: false,
		},
	})

	if err := app.Run(); err != nil {
		log.Fatal(err)
	}
}
```

- [ ] **步骤 4：创建 Go 模块依赖**

```bash
cd simple_live_desktop
go mod tidy
```

预期：go.mod 和 go.sum 生成成功

- [ ] **步骤 5：初始化前端项目**

```bash
cd simple_live_desktop
mkdir -p frontend/src
cd frontend
npm create vite@latest . -- --template vue 2>&1 | tail -5
npm install
```

- [ ] **步骤 6：安装依赖（mpegts.js + hls.js）**

```bash
cd simple_live_desktop/frontend
npm install mpegts.js hls.js
```

- [ ] **步骤 7：验证项目能编译**

```bash
cd simple_live_desktop
go mod tidy
wails build
```

预期：编译成功，生成 build/bin/SimpleLive.app

---

### 任务 2：Go 后端播放地址 API

**文件：**
- 创建：`simple_live_desktop/app.go`
- 创建：`simple_live_desktop/backend/player/provider.go`

- [ ] **步骤 1：创建 App 结构体（Wails 绑定）**

`simple_live_desktop/app.go`：

```go
package main

import (
	"context"
	"simple_live_desktop/backend/player"
)

type App struct {
	playerService *player.Service
}

func NewApp() *App {
	return &App{
		playerService: player.NewService(),
	}
}

// GetTestPlayUrl 返回一个测试用的 HTTP-FLV 播放地址
// 使用 B站官方测试流: https://live.bilibili.com/6 (B站官方直播测试)
func (a *App) GetTestPlayUrl(ctx context.Context) (map[string]interface{}, error) {
	return a.playerService.GetTestUrl()
}

// GetPlayUrl 解析指定平台的播放地址
func (a *App) GetPlayUrl(ctx context.Context, siteId, roomId string) (map[string]interface{}, error) {
	return a.playerService.GetPlayUrl(siteId, roomId)
}
```

- [ ] **步骤 2：创建播放器服务**

`simple_live_desktop/backend/player/provider.go`：

```go
package player

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

type Service struct {
	client *http.Client
}

type PlayUrlResult struct {
	Urls  []string          `json:"urls"`
	Type  string            `json:"type"` // flv / hls / mp4
	Extra map[string]string `json:"extra,omitempty"`
}

func NewService() *Service {
	return &Service{
		client: &http.Client{},
	}
}

// GetTestUrl 返回 B站官方测试流地址
func (s *Service) GetTestUrl() (map[string]interface{}, error) {
	// 使用已知可用的 HTTP-FLV 测试流
	result := PlayUrlResult{
		Urls: []string{
			// B站官方 24h 直播测试流 (HLS)
			"https://live-play.acgvideo.com/live/6_1/index.m3u8",
		},
		Type: "hls",
	}

	return map[string]interface{}{
		"urls":      result.Urls,
		"type":      result.Type,
		"site":      "bilibili",
		"room_name": "B站官方直播测试",
	}, nil
}

// GetPlayUrl 解析指定平台的播放地址
// Phase 0 中仅做简单的 HTTP 请求验证，Phase 1 才接入完整协议解析
func (s *Service) GetPlayUrl(siteId, roomId string) (map[string]interface{}, error) {
	switch siteId {
	case "bilibili":
		return s.getBilibiliPlayUrl(roomId)
	case "douyin":
		return s.getDouyinPlayUrl(roomId)
	default:
		return nil, fmt.Errorf("不支持的平台: %s", siteId)
	}
}

func (s *Service) getBilibiliPlayUrl(roomId string) (map[string]interface{}, error) {
	// 调用 B站 API 获取播放地址
	apiURL := fmt.Sprintf("https://api.live.bilibili.com/room/v1/Room/playUrl?cid=%s&qn=10000&platform=web", roomId)
	resp, err := s.client.Get(apiURL)
	if err != nil {
		return nil, fmt.Errorf("请求B站API失败: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var result map[string]interface{}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, err
	}

	data, ok := result["data"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("B站API返回格式异常")
	}

	durl, ok := data["durl"].([]interface{})
	if !ok || len(durl) == 0 {
		return nil, fmt.Errorf("未找到播放地址")
	}

	var urls []string
	for _, item := range durl {
		if m, ok := item.(map[string]interface{}); ok {
			if u, ok := m["url"].(string); ok {
				urls = append(urls, u)
			}
		}
	}

	urlType := "flv"
	if len(urls) > 0 && strings.Contains(urls[0], ".m3u8") {
		urlType = "hls"
	}

	return map[string]interface{}{
		"urls":      urls,
		"type":      urlType,
		"site":      "bilibili",
		"room_name": "",
	}, nil
}

func (s *Service) getDouyinPlayUrl(roomId string) (map[string]interface{}, error) {
	// Phase 0: 返回占位信息，Phase 1 实现
	return nil, fmt.Errorf("抖音播放地址解析将在 Phase 1 实现")
}
```

- [ ] **步骤 3：注册 App 到 main.go**

修改 `simple_live_desktop/main.go`，添加 App 绑定：

```go
package main

import (
	"context"
	"embed"
	"fmt"
	"log"

	"github.com/wailsapp/wails/v3/pkg/application"
)

//go:embed frontend/dist/*
var assets embed.FS

func main() {
	app := application.New(application.Options{
		Name:        "Simple Live",
		Description: "直播观看客户端",
		Mac: application.MacOptions{
			ActivationPolicy: application.ActivationPolicyRegular,
		},
		Assets: application.AssetOptions{
			Handler: application.BundledAssetFileServer(assets),
		},
	})

	// 注册 App 绑定
	app.RegisterBindings([]interface{}{NewApp()}...)

	app.NewWebviewWindow(application.WebviewWindowOptions{
		Title:  "Simple Live",
		Width:  1280,
		Height: 800,
		Mac: application.MacWindowOptions{
			TitleBar:          application.TitleBarDefault,
			Appearance:        application.NSAppearanceNameDarkAqua,
			InvisibleTitleBar: false,
		},
	})

	if err := app.Run(); err != nil {
		log.Fatal(err)
	}
}
```

- [ ] **步骤 4：验证编译**

```bash
cd simple_live_desktop
go mod tidy
go build -o ./build/bin/SimpleLive ./...
```

预期：编译成功

---

### 任务 3：前端视频播放器页面

**文件：**
- 创建：`simple_live_desktop/frontend/src/App.vue`
- 创建：`simple_live_desktop/frontend/src/main.js`
- 创建：`simple_live_desktop/frontend/src/views/PlayerTest.vue`

- [ ] **步骤 1：创建 Vue 入口**

`simple_live_desktop/frontend/src/main.js`：

```javascript
import { createApp } from 'vue'
import App from './App.vue'

createApp(App).mount('#app')
```

`simple_live_desktop/frontend/src/App.vue`：

```vue
<template>
  <div id="app">
    <PlayerTest />
  </div>
</template>

<script setup>
import PlayerTest from './views/PlayerTest.vue'
</script>

<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body, #app { width: 100%; height: 100%; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; }
</style>
```

- [ ] **步骤 2：创建播放器验证页面**

`simple_live_desktop/frontend/src/views/PlayerTest.vue`：

```vue
<template>
  <div class="player-test">
    <div class="header">
      <h2>Simple Live - 播放验证</h2>
      <div class="controls">
        <input v-model="roomId" placeholder="输入房间ID" class="input" />
        <select v-model="siteId" class="select">
          <option value="bilibili">B站</option>
          <option value="douyin">抖音</option>
          <option value="test">测试流</option>
        </select>
        <button @click="loadStream" :disabled="loading" class="btn">
          {{ loading ? '加载中...' : '播放' }}
        </button>
      </div>
      <div class="info" v-if="streamInfo">
        <span>类型: {{ streamInfo.type }}</span>
        <span v-if="streamInfo.urls">线路: {{ streamInfo.urls.length }}</span>
      </div>
    </div>

    <div class="player-container" ref="playerContainer">
      <video ref="videoEl" class="video" controls autoplay muted></video>
      <div v-if="!streamLoaded" class="placeholder">
        <p>输入房间号，点击播放</p>
        <p class="hint">测试流: B站 6 (官方测试)</p>
      </div>
      <div v-if="error" class="error-msg">{{ error }}</div>
    </div>

    <div class="log">
      <div v-for="(msg, i) in logs" :key="i" class="log-line">{{ msg }}</div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted, nextTick } from 'vue'
import mpegts from 'mpegts.js'
import Hls from 'hls.js'

const videoEl = ref(null)
const playerContainer = ref(null)
const roomId = ref('6')
const siteId = ref('test')
const loading = ref(false)
const streamLoaded = ref(false)
const error = ref('')
const streamInfo = ref(null)
const logs = ref([])

let mpegtsPlayer = null
let hlsPlayer = null

function addLog(msg) {
  logs.value.push(`[${new Date().toLocaleTimeString()}] ${msg}`)
}

function destroyPlayer() {
  if (mpegtsPlayer) {
    mpegtsPlayer.destroy()
    mpegtsPlayer = null
  }
  if (hlsPlayer) {
    hlsPlayer.destroy()
    hlsPlayer = null
  }
  streamLoaded.value = false
}

async function loadStream() {
  destroyPlayer()
  error.value = ''
  loading.value = true
  streamInfo.value = null

  try {
    let result
    if (siteId.value === 'test') {
      // 使用 GetTestPlayUrl
      result = await window.runtime.call('GetTestPlayUrl')
    } else {
      result = await window.runtime.call('GetPlayUrl', siteId.value, roomId.value)
    }

    streamInfo.value = result
    addLog(`获取播放地址成功: ${result.type}`)
    addLog(`URL: ${result.urls[0]}`)

    await nextTick()
    startPlay(result.urls[0], result.type, result.urls)
  } catch (e) {
    error.value = `获取播放地址失败: ${e.message || e}`
    addLog(`错误: ${e.message || e}`)
  } finally {
    loading.value = false
  }
}

function startPlay(url, type, urls) {
  if (!videoEl.value) return

  if (type === 'flv' && mpegts.isSupported()) {
    addLog('使用 mpegts.js 播放 FLV')
    mpegtsPlayer = mpegts.createPlayer({
      type: 'flv',
      url: url,
      isLive: true,
    })
    mpegtsPlayer.attachMediaElement(videoEl.value)
    mpegtsPlayer.load()
    mpegtsPlayer.play()
    streamLoaded.value = true

    mpegtsPlayer.on(mpegts.Events.ERROR, (err) => {
      error.value = `播放错误: ${err}`
      addLog(`mpegts错误: ${err}`)
    })
  } else if ((type === 'hls' || url.includes('.m3u8')) && Hls.isSupported()) {
    addLog('使用 hls.js 播放 HLS')
    hlsPlayer = new Hls()
    hlsPlayer.loadSource(url)
    hlsPlayer.attachMedia(videoEl.value)
    streamLoaded.value = true

    hlsPlayer.on(Hls.Events.ERROR, (event, data) => {
      if (data.fatal) {
        error.value = `HLS播放错误: ${data.type}`
        addLog(`HLS错误: ${data.type} - ${data.details}`)
      }
    })
  } else if (url.includes('.m3u8') && videoEl.value.canPlayType('application/vnd.apple.mpegurl')) {
    // Safari native HLS
    addLog('使用原生 HLS 播放')
    videoEl.value.src = url
    videoEl.value.play()
    streamLoaded.value = true
  } else {
    error.value = `不支持的播放格式: ${type}`
    addLog(`不支持的格式: ${type}`)
  }
}

onMounted(() => {
  addLog(`mpegts.js 支持: ${mpegts.isSupported()}`)
  addLog(`hls.js 支持: ${Hls.isSupported()}`)
  addLog('页面已加载，等待播放')
})

onUnmounted(() => {
  destroyPlayer()
})
</script>

<style scoped>
.player-test {
  display: flex;
  flex-direction: column;
  height: 100vh;
  background: #1a1a2e;
  color: #e0e0e0;
}
.header {
  padding: 12px 16px;
  background: #16213e;
  border-bottom: 1px solid #0f3460;
}
.header h2 { margin-bottom: 8px; font-size: 18px; }
.controls { display: flex; gap: 8px; margin-bottom: 8px; }
.input, .select {
  padding: 8px 12px;
  border: 1px solid #0f3460;
  border-radius: 6px;
  background: #1a1a2e;
  color: #e0e0e0;
  font-size: 14px;
}
.input { flex: 1; }
.btn {
  padding: 8px 20px;
  background: #e94560;
  color: white;
  border: none;
  border-radius: 6px;
  cursor: pointer;
  font-size: 14px;
}
.btn:disabled { opacity: 0.5; }
.info { font-size: 12px; color: #aaa; display: flex; gap: 16px; }
.player-container {
  flex: 1;
  position: relative;
  background: #000;
  display: flex;
  align-items: center;
  justify-content: center;
}
.video {
  width: 100%;
  height: 100%;
  object-fit: contain;
}
.placeholder {
  position: absolute;
  color: #666;
  text-align: center;
}
.placeholder .hint { font-size: 12px; margin-top: 8px; color: #555; }
.error-msg {
  position: absolute;
  bottom: 16px;
  left: 16px;
  right: 16px;
  padding: 8px 12px;
  background: rgba(233, 69, 96, 0.9);
  border-radius: 6px;
  font-size: 13px;
}
.log {
  height: 120px;
  overflow-y: auto;
  background: #0d1117;
  padding: 8px 12px;
  font-family: monospace;
  font-size: 11px;
  border-top: 1px solid #0f3460;
}
.log-line { padding: 1px 0; }
</style>
```

- [ ] **步骤 3：验证前端能编译**

```bash
cd simple_live_desktop/frontend
npm run build
```

预期：`frontend/dist/` 目录生成

---

### 任务 4：编译并运行验证

- [ ] **步骤 1：完整编译**

```bash
cd simple_live_desktop
go mod tidy
wails build
```

预期：`build/bin/SimpleLive.app` 生成

- [ ] **步骤 2：运行并手动测试**

```bash
open build/bin/SimpleLive.app
```

手动测试项：
1. ✅ 默认加载测试流（B站 6），视频是否正常播放
2. ✅ 切换音频、拖动进度、全屏是否正常
3. ✅ 输入 B站其他房间号（如 1、3），是否能播放
4. ✅ 点击"播放"按钮时日志区域显示正确的调试信息
5. ✅ 窗口缩放时视频自适应

- [ ] **步骤 3：验证各播放方案**

在测试页面的不同场景：
1. **HLS 流** — B站默认返回的是 FLV + HLS 混合，验证 hls.js 是否正常工作
2. **FLV 流** — 如果 B站返回 FLV 地址，验证 mpegts.js 是否正常工作
3. **错误处理** — 输入不存在的房间号，验证错误提示

---

### 任务 5：产出行可行性报告

- [ ] **步骤 1：编写报告**

创建 `docs/superpowers/reports/2026-07-24-wails-playback-verification.md`：

```markdown
# Wails v3 播放验证报告

## 测试环境
- macOS: 26.5.2 (arm64)
- Wails v3: [版本号]
- 浏览器 WebView: WKWebView (macOS 内置)
- mpegts.js: [版本号]
- hls.js: [版本号]

## 测试结果

| 测试项 | 结果 | 备注 |
|--------|------|------|
| FLV (mpegts.js) | ✅/❌ | |
| HLS (hls.js) | ✅/❌ | |
| 原生 HLS (Safari) | ✅/❌ | |
| B站房间播放 | ✅/❌ | |
| 多画质切换 | ✅/❌ | |
| 全屏 | ✅/❌ | |
| 窗口缩放 | ✅/❌ | |
| 音频控制 | ✅/❌ | |

## 发现的问题
1. ...
2. ...

## 结论
- [ ] 播放方案可行，继续 Phase 1
- [ ] 播放方案有兼容性问题，需要调整
- [ ] 播放方案不可行，需要更换方案

## 下一步建议
- ...
```

- [ ] **步骤 2：提交到 git**

```bash
git add docs/superpowers/reports/2026-07-24-wails-playback-verification.md
git commit -m "report: Phase 0 播放验证报告"
```
