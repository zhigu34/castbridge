# M1 — AirPlay 接入验证

本阶段只验证原生 AirPlay Receiver，不要求浏览器已经显示投屏画面。

目标链路：

```text
iPhone / iPad / Mac
        │
        │ AirPlay
        ▼
     UxPlay 1.74
        │
        ├── H.264 RTP -> 127.0.0.1:5000
        └── L16 RTP  -> 127.0.0.1:5002
```

## 部署方式

继续使用项目统一命令：

```bash
git pull && ./deploy.sh && docker image prune -f
```

M1 新增 `castbridge-receiver` 容器。该容器使用 `network_mode: host`，原因是 AirPlay 设备发现依赖局域网 mDNS，Receiver 需要直接参与宿主机网络。

默认配置：

```dotenv
CASTBRIDGE_RECEIVER_NAME=CastBridge
UXPLAY_VERSION=1.74
CASTBRIDGE_AIRPLAY_PORT=7100
CASTBRIDGE_RTP_VIDEO_PORT=5000
CASTBRIDGE_RTP_AUDIO_PORT=5002
```

UxPlay 使用 `-p 7100` 后，会使用 TCP/UDP 7100、7101、7102 三个端口。

服务发现使用 UxPlay 1.74 内置 mDNSResponder，因此不要求额外部署 Avahi 容器。

## 防火墙

至少需要允许同一局域网访问：

```text
UDP 5353        mDNS / AirPlay 服务发现
TCP 7100-7102   AirPlay 控制与媒体连接
UDP 7100-7102   AirPlay 媒体相关端口
```

5000/5002 当前只作为本机 RTP 输出，不需要向局域网开放。

## 验证步骤

部署完成后执行：

```bash
docker compose ps
docker compose logs --tail=100 receiver
```

正常情况下 `castbridge-receiver` 应显示为 `healthy`。

浏览器首页也会显示：

```text
Receiver      正常
接收引擎       UxPlay 1.74
AirPlay 端口   7100-7102
```

然后在 Apple 设备上：

1. 确认设备与 CastBridge 服务器处于同一局域网。
2. 打开“控制中心”。
3. 进入“屏幕镜像”。
4. 查找 `CastBridge`。
5. 选择该设备并尝试连接。

本阶段即使连接后浏览器没有画面也是正常的。UxPlay 已将媒体导出到 RTP，浏览器显示属于 M2。

## 后端状态接口

```text
GET /api/v1/receiver
```

示例：

```json
{
  "healthy": true,
  "state": "ready",
  "receiver_name": "CastBridge",
  "engine": "UxPlay",
  "engine_version": "1.74",
  "airplay_port": 7100,
  "video_rtp_port": 5000,
  "audio_rtp_port": 5002
}
```

Receiver 容器每 2 秒写入一次心跳文件：

```text
run/receiver-status.json
```

后端只读取该文件，不直接访问 Docker Socket。

## RTP 输出

视频使用 UxPlay `-vrtp`：

```text
H.264 RTP -> 127.0.0.1:5000
```

音频使用 UxPlay `-artp`：

```text
L16 RTP -> 127.0.0.1:5002
```

第一版不开启 H.265，先把浏览器兼容性最好的 H.264 链路跑通。

## 常见问题

### 手机找不到 CastBridge

优先检查：

```bash
docker compose ps
docker compose logs --tail=200 receiver
```

然后检查宿主机防火墙是否允许 UDP 5353，以及手机和服务器之间是否存在 AP Isolation、访客网络隔离、VLAN ACL 或禁止组播的设置。

### Receiver 容器反复重启

查看：

```bash
docker compose logs -f receiver
```

重点关注：

- `Address already in use`
- mDNS 初始化错误
- 7100-7102 端口冲突
- GStreamer 插件缺失

### 修改投屏名称

编辑 `.env`：

```dotenv
CASTBRIDGE_RECEIVER_NAME=会议室投屏
```

然后：

```bash
./deploy.sh
```

## M1 当前完成定义

代码侧完成：

- UxPlay Receiver Docker 镜像。
- Compose host-network Receiver 服务。
- 固定 AirPlay 端口。
- H.264/L16 RTP 导出。
- Receiver 心跳状态。
- 后端 Receiver API。
- Web 首页 Receiver 状态。
- 一键部署集成。

仍需真机验证：

- iPhone/iPad/macOS 能发现 `CastBridge`。
- 实际连接成功。
- 连接/断开日志行为。
- RTP 5000/5002 确实收到媒体包。

这些真机结果确认后，再进入 M2 WebRTC 视频桥接。
