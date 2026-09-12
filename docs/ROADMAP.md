# CastBridge 开发路线图

这份路线图的核心原则是：**先验证最难、最不确定的技术链路，再做完整 UI 和多协议抽象。**

## 核心验收目标

第一阶段的成功标准不是“后台看起来很完整”，而是：

> **iPhone 能在“屏幕镜像”中发现 CastBridge，并把实时画面低延迟显示到 Windows / macOS 浏览器中。**

其他功能都建立在这条链路稳定之后。

---

## M0 — 项目基础

### 目标

建立可重复的开发环境，明确各组件边界。

### 任务

- [x] 创建 GitHub 仓库。
- [x] 编写项目说明。
- [x] 定义初始系统架构。
- [x] 编写阶段性开发路线图。
- [x] 编写开发规范。
- [ ] 创建 FastAPI 后端骨架。
- [ ] 创建 Vue 3 + TypeScript + Vite 前端骨架。
- [ ] 配置 Python / Node lint 和格式化。
- [ ] 建立统一配置模型。
- [ ] 加入后端 / 前端基础 CI。
- [ ] 增加 Makefile 或 Taskfile，统一常用开发命令。

### 完成标准

- 后端可以启动并提供 `/api/health`。
- 前端可以启动并查询后端健康状态。
- 每次 push / PR 自动执行 CI。
- 本地环境搭建步骤有明确文档且可重复执行。

---

## M1 — AirPlay 接入验证

### 目标

验证原生设备发现，并从 AirPlay 会话中提取媒体流，而不是直接在本机窗口播放。

### 任务

- [ ] 明确开发环境支持的 Linux 发行版和依赖包。
- [ ] 安装 / 编译固定版本 UxPlay。
- [ ] 由 Receiver Manager 启动 UxPlay。
- [ ] 支持配置广播名称，默认 `CastBridge`。
- [ ] 验证 iPhone / iPad / macOS 可以发现 CastBridge。
- [ ] 验证发送端连接 / 断开生命周期。
- [ ] 通过 UxPlay `-vrtp` 导出视频。
- [ ] 通过 UxPlay `-artp` 导出音频。
- [ ] 记录 RTP 元数据：codec、payload type、clock rate、resolution、fps。
- [ ] 为 Receiver 事件增加结构化日志。

### 原型交付物

先做一个 CLI / 调试管线：

```text
iPhone -> AirPlay -> UxPlay -> RTP -> 本地测试 Sink
```

此阶段不要求浏览器参与。

### 完成标准

- iPhone 能在“屏幕镜像”中发现 `CastBridge`。
- 连续镜像至少 30 分钟，Receiver 不崩溃。
- 视频 RTP 可由本地 GStreamer 管线检查和播放。
- 音频 RTP 可以独立检查和播放。
- 发送端断开能被稳定识别。

---

## M2 — WebRTC 浏览器视频

### 目标

让一个浏览器实时显示镜像视频。

### 任务

- [ ] 基于 GStreamer 实现 Media Worker。
- [ ] 接收 UxPlay 视频 RTP。
- [ ] 解析和规范化 H.264。
- [ ] 搭建第一版 `webrtcbin` 管线。
- [ ] 在 FastAPI 中实现 WebSocket 信令。
- [ ] 实现浏览器端 `RTCPeerConnection`。
- [ ] 完成 SDP / ICE 交换。
- [ ] 将远程视频流绑定到 `<video>`。
- [ ] 加入 Session ID 和浏览器重连逻辑。
- [ ] 采集 `getStats()` 指标。

### 首要实验

优先验证零转码：

```text
RTP/H.264 -> depay -> parse -> pay -> WebRTC
```

如果浏览器协商失败，必须先记录并明确失败原因，再决定是否增加转码路径。

### 完成标准

- 一个浏览器能实时显示 iPhone / iPad / Mac 镜像画面。
- Windows Chrome / Edge 可用。
- macOS Chrome 或 Safari 可用。
- 浏览器刷新后无需手工重启服务器即可恢复。
- 普通有线 / Wi-Fi 局域网下 1080p / 30 FPS 基线稳定。
- 已测量并记录端到端延迟。

### 决策节点

M2 完成后新增 ADR，记录：

- 实际观察到的 H.264 Profile / Level。
- 是否能稳定透传。
- 是否需要转码兜底。
- WebRTC Offer / Answer 的最终发起方模型。

---

## M3 — 音频与音画同步

### 目标

加入可靠的浏览器音频，并维持长期音画同步。

### 任务

- [ ] 接收 UxPlay L16 RTP 音频。
- [ ] 统一采样格式 / 采样率 / 声道。
- [ ] 编码成 Opus。
- [ ] 将 Opus Track 加入 WebRTC 会话。
- [ ] 测试 30 分钟以上会话的 A/V drift。
- [ ] 根据实际情况调整 jitter buffer / queue。
- [ ] 正确处理浏览器 autoplay 限制。
- [ ] 增加静音 / 取消静音 UI。

### 完成标准

- 浏览器同时接收到视频和音频。
- 长时间运行后没有明显音画漂移。
- 断开 / 重连不会遗留卡死的音频管线。
- 浏览器自动播放被拦截时，UI 明确提示用户操作。

---

## M4 — 产品化 Web 界面

### 目标

把技术原型整理成非技术用户也能使用的浏览器产品。

### 页面状态

- `BOOTING`
- `READY`
- `CONNECTING`
- `PLAYING`
- `RECONNECTING`
- `ERROR`

### 任务

- [ ] 实现全屏显示页面。
- [ ] 展示接收器名称和就绪状态。
- [ ] 能获取时显示发送端 / Session 信息。
- [ ] 从待机自动切换到播放。
- [ ] 发送端断开后自动回到待机。
- [ ] 增加全屏按钮。
- [ ] 增加流媒体统计面板。
- [ ] 增加 Receiver 重启动作。
- [ ] 增加人类可读的错误诊断。
- [ ] 完成桌面浏览器响应式布局。

### 完成标准

非技术用户可以：

1. 打开 CastBridge 页面。
2. 看到应该在手机中选择哪个接收器名称。
3. 在 Apple 设备上启动屏幕镜像。
4. 浏览器自动显示画面。
5. 停止镜像后页面自动回到 READY。

---

## M5 — 稳定性与部署

### 目标

让 CastBridge 从开发 Demo 变成可以长期运行的局域网服务。

### 任务

- [ ] 明确正式支持的 Linux 发行版。
- [ ] 增加 Receiver / Media 进程监督。
- [ ] 增加启动就绪检查。
- [ ] 增加带频率限制的自动重启。
- [ ] 完善 `/api/health` 和 `/api/ready`。
- [ ] 增加日志轮转和结构化日志说明。
- [ ] 支持配置文件 / 环境变量。
- [ ] 验证宿主机 systemd 部署。
- [ ] 评估 Docker + host network 部署。
- [ ] 增加 HTTPS 反向代理示例。
- [ ] 编写升级 / 卸载文档。
- [ ] 明确第三方依赖和 License 打包策略。

### 稳定性测试

- [ ] 空闲运行 8 小时。
- [ ] 连续投屏 4 小时。
- [ ] 50 次连接 / 断开循环。
- [ ] 活跃投屏期间连续 20 次浏览器刷新 / 重连。
- [ ] 发送端异常消失。
- [ ] Receiver 进程被 kill 后自动恢复。
- [ ] Media 进程被 kill 后自动恢复。

### 完成标准

一台干净 Linux 主机按照安装文档操作后，无需修改源代码即可成为可用的 CastBridge 接收器。

---

## M6 — 多观看端模式

### 目标

允许多个浏览器同时观看同一次投屏。

### 第一阶段

先测量 Peer-per-viewer 的直接分发模式。

### 决策原则

如果 CPU 或带宽随观看端数量明显恶化，则引入 SFU，而不是复制高成本媒体处理链路。

届时可评估：

- LiveKit
- mediasoup
- 基于 Pion 的自建服务

在实际测试证明需要之前，不提前引入 SFU。

### 完成标准

- 目标局域网硬件上至少支持 3 个浏览器同时观看。
- 新 Viewer 可以在投屏进行中加入。
- 一个 Viewer 断开不会影响其他 Viewer。

---

## M7 — 扩展其他投屏协议

每种协议单独研究和验证，不把进度绑在一起。

### Miracast

重点研究：

- Linux Miracast Sink 实现方案。
- Wi-Fi Direct 对硬件 / 驱动的要求。
- Infrastructure Mode / MS-MICE 可行性。
- NetworkManager / wpa_supplicant 冲突。
- 如何把 RTP 输出接入现有 Media Bridge。

目标链路：

```text
Windows / 支持 Miracast 的 Android
        -> Miracast
        -> CastBridge
        -> 现有 WebRTC Viewer
```

### Google Cast

重点研究：

- 设备发现。
- Receiver 身份认证 / 认证体系限制。
- Cast Web Receiver App 与“实现一个 Cast 接收设备”之间的区别。
- 自托管通用 Cast Receiver 是否现实且兼容。

在真实发送端 App 完成互操作验证之前，不对外宣称 Google Cast 兼容。

### DLNA

DLNA 更适合媒体播放，不等同于整个屏幕镜像。

将其作为单独的“将媒体播放到 CastBridge”功能，而不是 Mirroring 功能。

---

# 推荐开发顺序

```text
1. 工程骨架
2. UxPlay 生命周期管理
3. RTP 视频检查
4. WebRTC 视频
5. 音频
6. Session 生命周期
7. Vue 产品界面
8. 稳定性
9. 部署打包
10. 多观看端
11. 更多协议
```

在第 4 步真正跑通之前，不投入大量精力做复杂后台、权限体系、品牌页面或过度协议抽象。

---

# 第一批开发任务拆分

开始编码后，第一批任务保持足够小，能独立开发和测试：

1. **初始化 FastAPI 后端**
   - health endpoint
   - settings model
   - structured logging

2. **初始化 Vue 前端**
   - router
   - API client
   - ready / health 页面

3. **实现 UxPlay Supervisor**
   - subprocess start / stop
   - receiver name 配置
   - 日志采集
   - 状态事件

4. **实现 RTP Probe Pipeline**
   - video UDP port
   - audio UDP port
   - 检查 caps 和 timestamps

5. **实现 WebRTC POC**
   - GStreamer `webrtcbin`
   - WebSocket signaling
   - 单浏览器 Video Track

6. **串联 Receiver Session 与 WebRTC Viewer**
   - active session event
   - viewer 自动播放
   - disconnect cleanup

---

# v0.1 完成定义

满足以下全部条件后，CastBridge v0.1 才算完成：

- CastBridge 可以运行在文档指定的 Linux 主机上。
- iPhone / iPad / Mac 能通过系统原生 AirPlay 屏幕镜像发现它。
- 发送端无需安装专用 App 即可连接。
- Windows 或 macOS 浏览器可以打开 CastBridge 网页观看实时屏幕。
- 音频正常。
- 系统可以承受正常的连接 / 断开以及浏览器刷新循环。
- 日志和状态信息足以诊断常见故障。
- 安装和日常使用方式有完整文档。

超出以上定义的内容统一进入后续版本。