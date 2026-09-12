# CastBridge 开发指南

## 开发原则

CastBridge 首先是一个媒体与网络项目，其次才是一个 Web 管理界面项目。

因此开发过程中应优先验证协议与媒体链路，而不是先堆叠 UI 和抽象层。

推荐工作方式：

1. 先用最小命令行管线验证媒体链路。
2. 对链路做真实测量。
3. 再封装为稳定接口。
4. 行为可重复后再加入正式 UI。

## 初始技术基线

- Python 3.12+
- FastAPI
- Vue 3
- TypeScript
- Vite
- GStreamer 1.x，并安装 WebRTC 相关插件
- UxPlay，作为第一阶段 AirPlay Receiver

正式开始开发后，应固定关键依赖版本，并通过明确升级流程更新。

## 规划目录结构

```text
backend/
frontend/
media/
receiver/
deploy/
docs/
```

### `backend/`

负责 API、配置、WebRTC 信令、Session 状态和进程编排。

### `frontend/`

负责浏览器显示页面和诊断 UI。

### `receiver/`

负责封装原生投屏 Receiver、协议 Adapter 和进程 Supervisor。

协议特定行为应集中在这里，不向前端泄漏。

### `media/`

负责 GStreamer Pipeline、WebRTC 集成、媒体能力和流统计。

### `deploy/`

在核心媒体链路稳定后，负责 systemd、Docker、反向代理等部署内容。

## API 设计规范

- 原始媒体数据不经过 FastAPI。
- Request / Response 使用明确的类型模型。
- Session 使用显式状态机，不用多个隐式 boolean 拼状态。
- 实时会话变化通过 WebSocket Event 推送。
- 错误同时包含稳定的机器可读 error code 和人类可读 message。
- 尽早在日志和事件里加入 `session_id`。

## 子进程规范

UxPlay 和 GStreamer 的进程调用涉及安全边界。

- 禁止把用户输入直接拼成 shell command string。
- 使用参数数组调用，默认禁用 shell 执行。
- 校验 receiver name 和媒体配置。
- 捕获 stdout / stderr。
- 记录 exit code 和 restart count。
- 自动重启必须限频，避免 crash loop。
- 退出时先尝试 graceful shutdown，再考虑 hard kill。

## 前端规范

- Viewer 使用明确的小型状态机。
- 不允许仅通过 `<video>.srcObject` 是否存在来推断整个播放状态。
- 浏览器 autoplay 被拦截时必须呈现明确 UI 状态。
- 浏览器拒绝自动全屏时应正常降级，不影响基本观看。
- 诊断面板应为可选功能，不遮挡核心画面。

## 媒体处理规范

- 优先透传 / repacketization，再考虑 transcode。
- 不假设编码参数，必须检查真实发送端输出。
- 初期开发可以记录完整 WebRTC SDP 用于分析，但生产环境默认不长期保存。
- 测量 packet loss、jitter、RTT、bitrate、resolution 和 frame rate。
- 如必须转码，要记录为什么需要转码，并对 CPU / GPU 成本做基准测试。

## 测试策略

### 单元测试

适合覆盖：

- 配置校验
- Session 状态转换
- Signaling Message 校验
- Receiver 进程输出解析
- 子进程命令参数生成

### 集成测试

适合覆盖：

- API + WebSocket 生命周期
- Mock Receiver Event
- Media Worker 启动 / 清理
- 浏览器重连语义

### 真机 / 手工兼容性测试

原生投屏必须用真实设备验证。

至少维护以下兼容性矩阵：

- sender device / model
- OS version
- protocol
- 实际 codec
- resolution / fps
- connection result
- audio result
- measured latency
- notes

不能仅因为代码路径存在或协议文档声称支持，就对外宣称某设备兼容。

## Commit 规范

优先采用简洁 Conventional Commit 前缀：

```text
feat: ...
fix: ...
docs: ...
test: ...
refactor: ...
chore: ...
```

一个 Commit 尽量只表达一个独立、可理解的改动。

## 分支策略

在贡献者规模较小时保持简单：

- `main` 始终尽量保持可运行。
- 非简单改动使用短生命周期 feature branch。
- CI 建立后通过 Pull Request 合并。

## 架构决策记录

原型阶段验证出的重要架构结论，应整理成 ADR 放在：

```text
docs/adr/
```

典型 ADR 包括：

- WebRTC Offerer 由谁承担。
- H.264 透传还是转码。
- 进程拓扑。
- 部署 / 网络模型。
- 如果最终需要 SFU，选择哪一个方案。

## 技术里程碑的完成定义

一个里程碑不能因为“代码能编译”就算完成，至少还应具备：

- 可重复的测试路径
- 出错时有清晰日志
- 断开 / 退出时能正确清理资源
- 性能敏感项有实际测量数据
- 对应文档已经同步更新

各阶段详细验收条件见 [ROADMAP.md](ROADMAP.md)。