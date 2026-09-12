# CastBridge

> 让任意浏览器成为无线投屏显示器。

CastBridge 是一个自托管投屏网关，用于接收 AirPlay 等原生无线投屏协议，并将输入的实时音视频桥接为 WebRTC，使 Windows、macOS、Linux、平板等设备只需打开现代浏览器即可观看镜像画面。

## 项目状态

当前进入 **M0 工程基础阶段**。第一阶段只打通一条可靠的端到端链路：

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
- 使用 Docker Compose 作为默认部署方式。
- 为 Miracast、Google Cast、DLNA 和基于 SFU 的多观看端模式保留清晰扩展路径。

## v0.1 暂不实现

- 从零实现 AirPlay 协议。
- Miracast / Wi-Fi Direct。
- Google Cast Receiver 兼容。
- 以公网穿透为主要使用场景。
- 远程键盘鼠标控制发送端。
- 绕过 DRM 保护内容。
- 以 4K/60 FPS 作为首发目标。

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
                         │                      │ Media Bridge │
                         │                      └──────┬───────┘
                         │                             │ WebRTC
                         │  ┌──────────────┐           │
                         │  │ FastAPI      │◄──────────┘
                         │  │ Signaling /  │
                         │  │ Session      │
                         │  └──────┬───────┘
                         └─────────┼─────────────────────┘
                                   │
                                   ▼
                         ┌──────────────────────┐
                         │ Vue 3 + TypeScript   │
                         │ Browser Display      │
                         └──────────────────────┘
```

## 技术栈

| 层 | 技术 | 职责 |
| --- | --- | --- |
| 原生投屏接收 | UxPlay | AirPlay 发现、会话处理、解密后媒体导出 |
| 媒体管线 | GStreamer | RTP 接入、编码处理、WebRTC 传输 |
| WebRTC | GStreamer `webrtcbin` | SDP / ICE / 媒体传输 |
| API / 信令 | FastAPI | Session、WebSocket 信令、状态、健康检查 |
| Web UI | Vue 3 + TypeScript | 浏览器观看、全屏、状态与诊断 |
| Web 入口 | Nginx | 静态文件、API 与 WebSocket 反向代理 |
| 部署 | Docker Compose + `deploy.sh` | 本地测试与局域网部署 |

## 当前目录结构

```text
castbridge/
├── backend/                 # FastAPI 控制面
│   ├── app/
│   └── tests/
├── frontend/                # Vue 3 + TypeScript
│   └── src/
├── docs/
│   ├── ARCHITECTURE.md
│   ├── DEVELOPMENT.md
│   └── ROADMAP.md
├── docker-compose.yml
├── deploy.sh
├── .env.example
└── README.md
```

`receiver/`、`media/` 等实现目录会在 M1/M2 开始时加入。

## 快速部署

默认部署方式与开发习惯为 Docker Compose。

```bash
git clone https://github.com/zhigu34/castbridge.git
cd castbridge
./deploy.sh
```

首次运行时，`deploy.sh` 会自动从 `.env.example` 创建 `.env`。

默认访问：

```text
http://<服务器IP>:8090
```

端口可在 `.env` 中修改：

```dotenv
CASTBRIDGE_WEB_PORT=8090
```

### 日常更新

推荐直接使用：

```bash
git pull && ./deploy.sh && docker image prune -f
```

`deploy.sh` 会执行：

1. 检查 Docker、Docker Compose 和基础命令。
2. 自动创建 `.env`。
3. 检查 Web 端口占用。
4. 校验 Compose 配置。
5. 构建前后端镜像。
6. 启动容器。
7. 等待后端和 Web 入口健康检查通过。
8. 失败时输出相关日志。

也支持：

```bash
./deploy.sh --check-only
./deploy.sh --no-build
```

常用命令：

```bash
make ps
make logs
make down
make test
```

## M0 当前能力

当前代码已具备：

- FastAPI 应用骨架。
- `/health`、`/api/health`、`/api/ready` 状态接口。
- `/ws/system` WebSocket 基础通道。
- Vue 3 + TypeScript 状态页面。
- Nginx 统一 Web 入口和反向代理。
- Docker Compose 前后端部署。
- `deploy.sh` 一键部署与健康检查。
- Python 后端基础测试。

此阶段页面还不会显示真实 AirPlay 画面，下一阶段 M1 将开始接入 UxPlay。

## 目标使用流程

1. 在局域网 Linux 主机部署 CastBridge。
2. Windows 或 macOS 打开 CastBridge 网页。
3. iPhone / iPad / Mac 打开 **屏幕镜像 / AirPlay**。
4. 选择 CastBridge 接收器名称。
5. 画面通过 WebRTC 自动出现在浏览器。
6. 发送端停止投屏后，网页自动回到等待页面。

## v0.1 性能目标

- 1080p 屏幕镜像。
- 30 FPS 基线，稳定后再评估 60 FPS。
- 局域网端到端延迟目标 `< 300 ms`，并继续优化。
- 发送端断开、观看页刷新后可自动恢复。
- 浏览器协商允许时优先 H.264 透传 / 重新封装，避免无必要的解码再编码。

## 文档

- [技术架构](docs/ARCHITECTURE.md)
- [开发指南](docs/DEVELOPMENT.md)
- [开发路线与实施计划](docs/ROADMAP.md)

## 开发阶段

- **M0 — 工程基础：** Docker Compose、FastAPI、Vue、状态 API、部署脚本。
- **M1 — AirPlay 接入：** UxPlay 稳定启动并导出视频/音频 RTP。
- **M2 — 浏览器视频：** RTP H.264 通过 WebRTC 进入浏览器。
- **M3 — 音频与音画同步：** 浏览器获得同步音视频。
- **M4 — 产品化界面：** 正式 Viewer、会话状态、全屏和诊断。
- **M5 — 稳定性与部署：** 进程监管、日志、升级和长期运行测试。
- **M6 — 多观看端：** 同一个投屏会话支持多个浏览器。
- **M7 — 协议扩展：** Miracast、Google Cast、DLNA 分别验证。

详见 [ROADMAP.md](docs/ROADMAP.md)。

## License

项目许可证暂未确定。UxPlay 使用 GPL-3.0，因此在决定最终许可证及发行方式前，需要先明确 UxPlay 的调用、打包和分发边界。

---

**CastBridge — 原生投屏输入，WebRTC 浏览器输出。**
