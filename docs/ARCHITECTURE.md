# CastBridge 系统架构

## 1. 目标

CastBridge 的核心目标，是把原生无线投屏协议输入转换为浏览器可直接观看的实时媒体流。

整个架构遵循一条基本原则：

> **原生投屏协议终止在 CastBridge 主机，浏览器只处理 WebRTC 和标准 Web API。**

这样就不需要尝试让浏览器自己实现 AirPlay、Miracast 或 Google Cast 的设备发现和接收逻辑。

## 2. v0.1 范围

第一阶段只支持以下链路：

```text
Apple 发送端
(iPhone / iPad / Mac)
        │
        │ AirPlay
        ▼
     UxPlay
        │
        │ RTP 音视频
        ▼
   Media Bridge
    (GStreamer)
        │
        │ WebRTC
        ▼
浏览器观看端
(Windows/macOS/Linux)
```

### v0.1 包含

- 局域网 AirPlay 发现和屏幕镜像。
- 每个接收器实例同时只接收一个发送端。
- 第一阶段支持单浏览器观看，但内部设计为可扩展到多个观看端。
- 以 H.264 作为视频基线。
- 音频传输和音画同步。
- 基于 WebSocket 的 WebRTC 信令。
- 投屏会话生命周期和可观测性。
- 优先支持 Linux 部署。

### v0.1 不包含

- 重新实现 AirPlay 协议。
- Miracast / Wi-Fi Direct。
- Google Cast。
- 以公网使用为首要目标。
- 绕过 DRM。
- 远程控制发送设备。

## 3. 逻辑组件

### 3.1 Receiver Manager

负责启动、管理和监督原生投屏接收进程。

主要职责：

- 启动 / 停止 UxPlay。
- 设置广播出去的接收器名称。
- 分配 RTP 输出端口。
- 检测接收器是否就绪。
- 检测发送端连接 / 断开。
- 将 stdout / stderr 转成结构化日志。
- 可恢复故障时自动重启接收器。
- 向后端暴露接收器状态。

v0.1 中 Receiver Manager 应把 UxPlay 当成独立外部进程管理，不嵌入、不修改 UxPlay 源码。

### 3.2 Media Bridge

负责把接收到的 RTP 媒体转换成浏览器可播放的 WebRTC 会话。

预期职责：

- 接收 UxPlay 导出的 H.264 / H.265 RTP 视频。
- 接收 UxPlay 导出的 L16 RTP 音频。
- 检测视频编码格式和浏览器协商能力。
- 能透传时优先做 H.264 重新封装 / RTP 重打包。
- 只有在浏览器协商或媒体格式不兼容时才转码。
- 将浏览器音频编码为 Opus。
- 维护时间戳和音画同步。
- 暴露 WebRTC 统计和管线健康状态。

概念性视频管线：

```text
UxPlay RTP/H264
    │
    ▼
udpsrc
    │
rtph264depay
    │
h264parse
    │
rtph264pay
    │
webrtcbin
    │
    ▼
Browser
```

概念性音频管线：

```text
UxPlay RTP/L16
    │
    ▼
udpsrc
    │
RTP depay
    │
audioconvert / audioresample
    │
opusenc
    │
rtpopuspay
    │
webrtcbin
    │
    ▼
Browser
```

以上只是设计级管线。实际 caps、payload type、clock rate、queue、jitter buffer 等参数必须用真实 UxPlay 输出验证后再固定。

### 3.3 Backend / Control Plane

FastAPI 负责控制面，而不是媒体转发面。

主要职责：

- WebSocket 信令：SDP / ICE。
- 接收器状态 API。
- Display / Viewer 注册。
- 会话生命周期管理。
- Health / Ready 接口。
- 配置接口。
- 向 Web UI 推送实时事件。
- 后续加入认证 / token 校验。

FastAPI **不转发原始视频帧**。

### 3.4 Frontend

前端使用 Vue 3 + TypeScript，作为浏览器显示端。

主要状态：

```text
BOOTING
  ↓
READY
  ↓
CONNECTING
  ↓
PLAYING
  ↓
DISCONNECTED
  ↓
READY
```

第一版观看页应支持：

- 待机 / 就绪页面。
- 显示当前投屏接收器名称。
- 显示发送端连接状态。
- WebRTC 视频播放。
- 全屏模式。
- 音频静音 / 取消静音。
- 基础流媒体诊断。
- 错误和重连状态。

## 4. 进程架构

v0.1 可以按四类进程理解：

```text
┌───────────────────────────────────────────────┐
│ Linux Host                                    │
│                                               │
│  castbridge-api        FastAPI                │
│       │                                       │
│       ├─────────────┐                         │
│       │             │                         │
│  receiver-manager   │                         │
│       │             │                         │
│     UxPlay          │                         │
│       │             │                         │
│   RTP Video/Audio   │                         │
│       ▼             ▼                         │
│  media-worker / GStreamer                     │
│       │                                       │
│       │ WebRTC                                │
└───────┼───────────────────────────────────────┘
        │
        ▼
  Browser Viewer
```

为了尽快验证媒体链路，第一版可以把 Receiver Manager 和 Media Worker 临时放在 FastAPI 服务进程中实现，但接口必须保持可拆分，方便后续独立进程化。

## 5. 会话模型

一个 CastBridge Session 代表一次发送端屏幕镜像会话。

建议模型：

```text
CastSession
├── id
├── receiver_id
├── state
├── sender_protocol        # 初期为 airplay
├── sender_name            # 能识别时记录
├── started_at
├── ended_at
├── video_codec
├── video_width
├── video_height
├── video_fps
├── audio_codec
├── viewer_count
└── failure_reason
```

建议状态：

```text
IDLE
RECEIVER_CONNECTED
MEDIA_DETECTED
WEBRTC_NEGOTIATING
STREAMING
STOPPING
ENDED
FAILED
```

状态变化通过事件推送给 Web UI，避免前端高频轮询。

## 6. WebRTC 信令

### WebSocket

建议接口：

```text
/ws/displays/{display_id}
```

统一消息结构：

```json
{
  "type": "webrtc.offer",
  "session_id": "...",
  "payload": {}
}
```

初始消息类型：

- `display.hello`
- `receiver.state`
- `session.started`
- `session.ended`
- `webrtc.offer`
- `webrtc.answer`
- `webrtc.ice`
- `webrtc.restart`
- `stream.stats`
- `error`

GStreamer 和浏览器谁作为 Offerer，需要在 WebRTC 原型阶段实测后确定。浏览器发 Offer 或服务端发 Offer 都可以，关键是长期保持统一。

## 7. REST API 草案

第一阶段接口：

```text
GET  /api/health
GET  /api/ready
GET  /api/v1/receiver
GET  /api/v1/session
GET  /api/v1/config
PUT  /api/v1/config/receiver
POST /api/v1/receiver/restart
```

初始配置保持简单：

```json
{
  "receiver_name": "CastBridge",
  "video": {
    "prefer_h264": true,
    "max_width": 1920,
    "max_height": 1080,
    "max_fps": 30
  }
}
```

## 8. 网络设计

CastBridge 主机需要同时处理两类完全不同的网络流量。

### 发送端 → CastBridge

AirPlay 的发现、控制和媒体端口由原生接收器处理。容器网络或系统防火墙不能阻止局域网 multicast / mDNS。

这是 Docker 部署中特别需要注意的问题。第一版应优先保证可用性，可以先采用 host network 或宿主机原生服务，不急于追求完全容器隔离。

### Browser → CastBridge

浏览器需要：

- HTTPS / HTTP：UI 和 API。
- WSS / WS：信令。
- ICE candidate 连通：WebRTC 媒体传输。

同局域网 v0.1 场景通常使用 host candidate 即可。直到需要跨 NAT / 跨网络时才考虑 TURN。

## 9. 部署策略

### 开发阶段

推荐环境：

```text
Linux Host
├── 本机安装 UxPlay
├── 本机安装 GStreamer
├── Python virtualenv 运行 FastAPI
└── Vue Dev Server
```

在媒体链路尚未验证之前，这种方式能最大程度减少容器网络带来的干扰。

### v0.1 打包部署

M3 完成后再比较两种路线：

1. **宿主机原生服务**：Receiver / Media 使用 systemd，前端打包为静态文件。
2. **混合容器方案**：API / UI 容器化，Receiver / Media 使用 host networking。

在 AirPlay 发现机制没有验证通过前，不把完全隔离的 Docker Compose 作为硬性目标。

## 10. 可观测性

各核心组件至少应暴露或记录：

- uptime
- 当前状态
- active session ID
- restart count
- last error
- negotiated codec
- video resolution / fps
- RTP packet counters
- WebRTC RTT / jitter / packet loss
- viewer count

日志中统一加入 `session_id`，便于把同一次投屏在 Receiver、Media、Signaling 和 Browser 之间串起来排查。

## 11. 故障恢复

| 故障 | 预期行为 |
| --- | --- |
| 浏览器刷新 | 尽量只重新协商 WebRTC，不重启 AirPlay |
| 发送端断开 | 停止 Media Worker，结束会话，UI 回到 READY |
| UxPlay 崩溃 | Supervisor 自动重启，并让 UI 显示临时不可用 |
| GStreamer 失败 | 关闭 WebRTC，重启 Media Worker，尽量保留 Receiver |
| 信令 WebSocket 丢失 | 浏览器使用有限指数退避重连 |
| 编码不支持 | 明确显示诊断信息，后续再考虑转码回退 |

## 12. 安全设计

v0.1 主要用于局域网，但不能把不安全做法固化进架构。

最低要求：

- API 不提供任意 shell 执行能力。
- 校验 receiver name 和所有命令参数。
- 不把用户原始字符串直接拼进 UxPlay / GStreamer shell 命令。
- 子进程使用结构化参数数组启动。
- SDP 和 ICE 一律视为不可信网络输入。
- 支持共享或不可信网络前加入 display/session token。
- 正式部署使用 HTTPS。
- 不宣称支持，也不尝试绕过 DRM 保护内容。

## 13. 第三方依赖边界

UxPlay 使用 GPL-3.0。CastBridge 初期应把 UxPlay 作为独立可执行程序调用，并在文档中明确依赖关系。

在发布包含 UxPlay 的二进制包、Docker 镜像或一键安装包之前，需要确认许可证和分发边界，再决定 CastBridge 自身的最终 License。

## 14. 后续扩展

AirPlay 路线稳定后，其他协议统一设计成独立 Receiver Adapter：

```text
ReceiverAdapter
├── AirPlayAdapter
├── MiracastAdapter
├── CastAdapter
└── DlnaAdapter
```

每个 Adapter 都把协议事件归一化成统一的内部 Session / Media 模型，使前端和 WebRTC 层保持与协议无关。

当多个浏览器同时观看时，应优先评估 SFU，而不是简单地为每个 Viewer 复制一条昂贵的上游媒体管线。

## 15. 必须通过原型验证的关键问题

以下问题必须由实测决定，而不是靠假设：

1. UxPlay 输出的 H.264 是否能稳定地不重新编码直接进入浏览器 WebRTC？
2. 不同 iPhone / iPad / macOS 实际输出的 H.264 Profile / Level / Packetization Mode 是什么？
3. UxPlay RTP 时间戳在音频转为 Opus 后是否还能长期维持稳定音画同步？
4. 长期看是由 GStreamer 直接负责 WebRTC Peer 协商，还是引入独立 WebRTC 服务更合理？
5. 哪种容器网络模式能可靠保留 AirPlay 发现？
6. 单个 Media Worker 能支撑多少浏览器 Viewer，什么时候必须引入 SFU？

这些问题在 M2 / M3 实测后，应整理为 ADR（Architecture Decision Record）记录到仓库。