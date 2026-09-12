# CastBridge

> 让任意浏览器成为无线投屏显示器。

CastBridge 是一个自托管投屏网关，用于接收 AirPlay 等原生无线投屏协议，并将输入的实时音视频桥接为 WebRTC，使 Windows、macOS、Linux、平板等设备只需打开现代浏览器即可观看镜像画面。

## 项目状态

**早期设计 / v0.1 规划阶段。** 第一阶段刻意只打通一条可靠的端到端链路：

**iPhone / iPad / Mac → AirPlay → CastBridge → WebRTC → 浏览器**

Miracast、Google Cast、DLNA、多观看端分发以及公网部署均放到后续阶段。

## 为什么做 CastBridge？

大多数无线投屏接收器最终都显示在本地原生应用窗口或 HDMI 屏幕上。CastBridge 将“投屏接收端”和“观看端”彻底解耦：

```text
发送设备                         CastBridge                         观看端
┌──────────────┐                ┌──────────────────────┐           ┌────────────────────┐
│ iPhone/iPad  │ -- AirPlay --> │ 接收器 / 媒体网关     │ --WebRTC->│ Chrome / Edge      │
│ Mac          │                │                      │           │ Safari / Firefox   │
└──────────────┘                └──────────────────────┘           └────────────────────┘
```

发送设备看到的是一台普通无线投屏设备，而观看端只需要浏览器。

## 项目目标

- 在局域网中作为原生 AirPlay 接收器被发现。
- 无需发送端安装专用 App，即可接收系统级屏幕镜像。
- 通过 WebRTC 低延迟转发媒体到浏览器。
- Windows 和 macOS 观看端无需安装任何客户端。
- 控制面与媒体面分离。
- 提供简洁的 Web UI，用于显示接收器状态、投屏会话、播放状态和诊断信息。
- 支持在 Linux 主机上可重复部署。
- 为 Miracast、Google Cast、DLNA 和基于 SFU 的多观看端模式保留清晰扩展路径。

## v0.1 暂不实现

- 从零实现 AirPlay 协议。
- Miracast / Wi-Fi Direct。
- Google Cast 接收兼容。
- 以公网穿透为主要使用场景。
- 远程键盘/鼠标控制发送端。
- 绕过 DRM 保护内容。
- 将 4K/60 FPS 作为首发要求。

## v0.1 架构

```text
                         ┌───────────────────────────────┐
                         │          CastBridge           │
                         │                               │
 iPhone / iPad / Mac     │  ┌──────────┐   RTP H.264   │
        │                │  │ UxPlay   │──────────────┐│
        │ AirPlay        │  │ Receiver │              ││
        └───────────────►│  └──────────┘              ▼│
                         │                      ┌──────────────┐
                         │                      │ GStreamer    │
                         │                      │ 媒体桥接      │
                         │                      └──────┬───────┘
                         │                             │ WebRTC
                         │  ┌──────────────┐           │
                         │  │ FastAPI      │◄──────────┘
                         │  │ 信令 / 会话   │
                         │  └──────┬───────┘
                         └─────────┼─────────────────────┘
                                   │
                                   ▼
                         ┌──────────────────────┐
                         │ Vue 3 + TypeScript   │
                         │ 浏览器显示端          │
                         └──────────────────────┘
```

### 技术栈

| 层级 | 技术 | 职责 |
| --- | --- | --- |
| 原生接收层 | UxPlay | AirPlay 发现、会话处理、解密后的媒体输出 |
| 媒体管线 | GStreamer | RTP 接入、编解码处理、WebRTC 传输 |
| WebRTC | GStreamer `webrtcbin` | SDP / ICE / 浏览器媒体传输 |
| API / 信令 | FastAPI | 会话、WebSocket 信令、状态、健康检查 |
| Web UI | Vue 3 + TypeScript | 观看页、全屏显示、会话状态、诊断信息 |
| 部署 | Docker / systemd | 可重复的局域网部署 |

UxPlay 1.73+ 提供 `-vrtp` 和 `-artp`，可以将接收到的媒体转发给外部管线，而不是只能在本机直接渲染。v0.1 优先利用这一能力，不修改 AirPlay 接收器本身。

## 目标目录结构

```text
castbridge/
├── backend/                 # FastAPI 后端
├── frontend/                # Vue 3 + TypeScript Web UI
├── media/                   # GStreamer / WebRTC 集成
├── receiver/                # 投屏协议接收器集成
├── deploy/                  # Docker、systemd、反向代理
├── docs/
│   ├── ARCHITECTURE.md
│   ├── DEVELOPMENT.md
│   └── ROADMAP.md
└── README.md
```

以上目录为目标结构，具体实现目录会随着各阶段开发逐步加入。

## 目标使用流程

1. 在局域网 Linux 主机上部署 CastBridge。
2. 在 Windows 或 macOS 上打开 CastBridge 显示页面。
3. 在 iPhone / iPad / Mac 中打开“屏幕镜像 / AirPlay”。
4. 选择 CastBridge 接收器名称。
5. 实时画面通过 WebRTC 自动出现在浏览器中。
6. 发送端停止投屏后，浏览器自动回到待机页面。

## v0.1 性能目标

- 支持 1080p 屏幕镜像。
- 以 30 FPS 为基线，稳定后再评估 60 FPS。
- 局域网端到端可见延迟目标：**低于 300 ms**，并持续向更低延迟优化。
- 发送端断开、浏览器刷新后可自动恢复。
- 浏览器协商允许时优先使用 H.264 透传 / 重新封装，避免不必要的解码再编码。

## 安全模型

v0.1 以局域网为主要使用场景，但仍保持基本安全边界：

- 多用户部署前，为浏览器信令增加认证或短时 display/session token。
- 接收器会话与观看端会话由 CastBridge 显式绑定。
- 正式部署时 Web UI 使用 HTTPS。
- 不尝试绕过 DRM 保护内容。
- 在认证和 TURN 策略明确之前，不把公网访问列为支持场景。

## 文档

- [系统架构](docs/ARCHITECTURE.md)
- [开发指南](docs/DEVELOPMENT.md)
- [开发路线图](docs/ROADMAP.md)

## 开发里程碑

- **M0 — 项目基础：** 工程骨架、架构、开发环境。
- **M1 — AirPlay 接入：** UxPlay 稳定启动并导出音视频 RTP。
- **M2 — 浏览器视频：** RTP H.264 通过 WebRTC 到达浏览器。
- **M3 — 音频与同步：** 浏览器获得同步的音视频。
- **M4 — 产品界面：** Vue 观看页、会话状态、全屏、诊断。
- **M5 — 打包部署：** Linux 部署、健康检查、日志、自动恢复。
- **M6 — 多观看端：** 同一投屏会话支持多个浏览器同时观看。
- **M7 — 协议扩展：** 分别评估 Miracast、Google Cast 和 DLNA。

详细验收标准与实施顺序见 [ROADMAP.md](docs/ROADMAP.md)。

## License

项目暂未选择最终 License。UxPlay 使用 GPL-3.0，因此在确定 CastBridge 与 UxPlay 的打包、分发边界之前，需要先评估许可证影响，再决定 CastBridge 的最终授权方式。

---

**CastBridge — 原生投屏接入，WebRTC 浏览器输出。**