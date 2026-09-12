<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'

type Health = {
  status: string
  service: string
  version: string
}

type Ready = {
  ready: boolean
  receiver: string
  receiver_ready: boolean
  receiver_state: string
  media_ready: boolean
  media_state: string
  environment: string
}

type Receiver = {
  healthy: boolean
  state: string
  receiver_name: string | null
  engine: string
  engine_version: string | null
  timestamp: string | null
  age_seconds: number | null
  airplay_port: number | null
  video_rtp_port: number | null
  audio_rtp_port: number | null
  message: string
}

type Media = {
  healthy: boolean
  streaming: boolean
  state: string
  engine: string
  video_rtp_port: number | null
  signaling_connected: boolean
  broker_connected: boolean
  active_viewer: string | null
  viewer_count: number
  peer_state: string
  video_active: boolean
  buffers: number
  bytes: number
  message: string
  error: string | null
}

type SignalMessage = {
  type: string
  viewer_id?: string
  media_connected?: boolean
  sdp?: string
  candidate?: string
  sdp_mline_index?: number
}

const health = ref<Health | null>(null)
const ready = ref<Ready | null>(null)
const receiver = ref<Receiver | null>(null)
const media = ref<Media | null>(null)
const error = ref('')
const socketState = ref<'连接中' | '已连接' | '未连接'>('连接中')
const viewerSocketState = ref<'连接中' | '已连接' | '未连接'>('连接中')
const webrtcState = ref('等待 Media Bridge')
const viewerId = ref('')
const videoElement = ref<HTMLVideoElement | null>(null)
const packetsReceived = ref(0)
const bytesReceived = ref(0)
const framesDecoded = ref(0)
const frameSize = ref('—')

let socket: WebSocket | null = null
let viewerSocket: WebSocket | null = null
let peer: RTCPeerConnection | null = null
let statusTimer: number | null = null
let statsTimer: number | null = null
let viewerReconnectTimer: number | null = null
let disposed = false
let pendingCandidates: RTCIceCandidateInit[] = []

const isReady = computed(() => (
  health.value?.status === 'ok'
  && receiver.value?.healthy === true
  && media.value?.healthy === true
))
const browserHasFrames = computed(() => framesDecoded.value > 0)
const receiverStateText = computed(() => {
  if (!receiver.value) return '检测中'
  if (receiver.value.healthy) return 'AirPlay 已就绪'
  if (receiver.value.state === 'unavailable') return 'Receiver 未启动'
  if (receiver.value.state === 'stopped') return 'Receiver 已停止'
  return receiver.value.message || receiver.value.state
})
const streamStateText = computed(() => {
  if (webrtcState.value === 'connected' && framesDecoded.value > 0) return 'WebRTC 视频已解码'
  if (webrtcState.value === 'connected' && packetsReceived.value > 0) return '已收到 WebRTC RTP，但浏览器尚未解码 H.264'
  if (webrtcState.value === 'connected') return 'WebRTC 已连接，等待视频包'
  if (media.value?.streaming) return 'H.264 视频流已到达 Media Bridge'
  if (media.value?.active_viewer) return '正在协商 WebRTC'
  if (media.value?.healthy) return '等待浏览器视频会话'
  return media.value?.message || 'Media Bridge 检测中'
})

async function loadStatus() {
  try {
    error.value = ''
    const [healthResponse, readyResponse, receiverResponse, mediaResponse] = await Promise.all([
      fetch('/api/health'),
      fetch('/api/ready'),
      fetch('/api/v1/receiver'),
      fetch('/api/v1/media'),
    ])
    if (!healthResponse.ok || !readyResponse.ok || !receiverResponse.ok || !mediaResponse.ok) {
      throw new Error('后端状态请求失败')
    }
    health.value = await healthResponse.json()
    ready.value = await readyResponse.json()
    receiver.value = await receiverResponse.json()
    media.value = await mediaResponse.json()
  } catch (reason) {
    error.value = reason instanceof Error ? reason.message : '无法连接 CastBridge 后端'
  }
}

function connectSocket() {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  socket = new WebSocket(`${protocol}//${window.location.host}/ws/system`)
  socket.onopen = () => { socketState.value = '已连接' }
  socket.onclose = () => { socketState.value = '未连接' }
  socket.onerror = () => { socketState.value = '未连接' }
}

function resetBrowserStats() {
  packetsReceived.value = 0
  bytesReceived.value = 0
  framesDecoded.value = 0
  frameSize.value = '—'
}

function resetPeer() {
  peer?.close()
  peer = null
  pendingCandidates = []
  resetBrowserStats()
  if (videoElement.value) videoElement.value.srcObject = null
}

function sendViewer(message: Record<string, unknown>) {
  if (viewerSocket?.readyState === WebSocket.OPEN) {
    viewerSocket.send(JSON.stringify(message))
  }
}

async function pollWebRTCStats() {
  const connection = peer
  if (!connection) return
  try {
    const stats = await connection.getStats()
    stats.forEach((report) => {
      const row = report as RTCStats & {
        type: string
        kind?: string
        mediaType?: string
        packetsReceived?: number
        bytesReceived?: number
        framesDecoded?: number
        frameWidth?: number
        frameHeight?: number
      }
      if (row.type !== 'inbound-rtp' || (row.kind ?? row.mediaType) !== 'video') return
      packetsReceived.value = row.packetsReceived ?? 0
      bytesReceived.value = row.bytesReceived ?? 0
      framesDecoded.value = row.framesDecoded ?? 0
      if (row.frameWidth && row.frameHeight) frameSize.value = `${row.frameWidth}×${row.frameHeight}`
    })
  } catch {
    // Peer may disappear while a reconnect is in progress.
  }
}

async function handleOffer(sdp: string) {
  resetPeer()
  webrtcState.value = 'negotiating'

  const connection = new RTCPeerConnection({ iceServers: [] })
  peer = connection

  connection.onicecandidate = (event) => {
    if (!event.candidate) return
    sendViewer({
      type: 'webrtc.ice',
      candidate: event.candidate.candidate,
      sdp_mline_index: event.candidate.sdpMLineIndex ?? 0,
    })
  }

  connection.ontrack = (event) => {
    const stream = event.streams[0] ?? new MediaStream([event.track])
    if (videoElement.value) {
      videoElement.value.srcObject = stream
      void videoElement.value.play().catch(() => undefined)
    }
  }

  connection.onconnectionstatechange = () => {
    webrtcState.value = connection.connectionState
  }

  await connection.setRemoteDescription({ type: 'offer', sdp })
  for (const candidate of pendingCandidates) {
    await connection.addIceCandidate(candidate)
  }
  pendingCandidates = []

  const answer = await connection.createAnswer()
  await connection.setLocalDescription(answer)
  if (answer.sdp) {
    sendViewer({ type: 'webrtc.answer', sdp: answer.sdp })
  }
}

async function handleViewerMessage(event: MessageEvent<string>) {
  let message: SignalMessage
  try {
    message = JSON.parse(event.data) as SignalMessage
  } catch {
    return
  }

  if (message.type === 'viewer.hello') {
    viewerId.value = message.viewer_id ?? ''
    if (!message.media_connected) webrtcState.value = '等待 Media Bridge'
    return
  }

  if (message.type === 'media.offline') {
    webrtcState.value = 'Media Bridge 离线'
    resetPeer()
    return
  }

  if (message.type === 'webrtc.offer' && message.sdp) {
    try {
      await handleOffer(message.sdp)
    } catch (reason) {
      webrtcState.value = 'failed'
      error.value = reason instanceof Error ? `WebRTC 协商失败: ${reason.message}` : 'WebRTC 协商失败'
    }
    return
  }

  if (message.type === 'webrtc.ice' && message.candidate) {
    const candidate: RTCIceCandidateInit = {
      candidate: message.candidate,
      sdpMLineIndex: message.sdp_mline_index ?? 0,
    }
    if (peer?.remoteDescription) {
      try {
        await peer.addIceCandidate(candidate)
      } catch {
        // ICE candidate may become obsolete during a reconnect.
      }
    } else {
      pendingCandidates.push(candidate)
    }
  }
}

function scheduleViewerReconnect() {
  if (disposed || viewerReconnectTimer !== null) return
  viewerReconnectTimer = window.setTimeout(() => {
    viewerReconnectTimer = null
    connectViewerSocket()
  }, 2000)
}

function connectViewerSocket() {
  if (disposed) return
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  viewerSocketState.value = '连接中'
  viewerSocket = new WebSocket(`${protocol}//${window.location.host}/ws/viewer`)

  viewerSocket.onopen = () => {
    viewerSocketState.value = '已连接'
  }
  viewerSocket.onmessage = (event) => {
    void handleViewerMessage(event as MessageEvent<string>)
  }
  viewerSocket.onerror = () => {
    viewerSocketState.value = '未连接'
  }
  viewerSocket.onclose = () => {
    viewerSocketState.value = '未连接'
    resetPeer()
    scheduleViewerReconnect()
  }
}

onMounted(() => {
  void loadStatus()
  statusTimer = window.setInterval(() => void loadStatus(), 3000)
  statsTimer = window.setInterval(() => void pollWebRTCStats(), 1000)
  connectSocket()
  connectViewerSocket()
})

onBeforeUnmount(() => {
  disposed = true
  socket?.close()
  viewerSocket?.close()
  resetPeer()
  if (statusTimer !== null) window.clearInterval(statusTimer)
  if (statsTimer !== null) window.clearInterval(statsTimer)
  if (viewerReconnectTimer !== null) window.clearTimeout(viewerReconnectTimer)
})
</script>

<template>
  <main class="shell">
    <section class="hero">
      <div class="brand-row">
        <div class="logo">CB</div>
        <div>
          <p class="eyebrow">CASTBRIDGE</p>
          <h1>让浏览器成为无线投屏显示器</h1>
        </div>
      </div>

      <p class="lead">
        M2 视频链路已接入。iPhone / iPad / Mac 连接 CastBridge 后，H.264 RTP 将由 GStreamer 转为 WebRTC 并直接显示在浏览器中。
      </p>

      <div class="status-card" :class="{ ready: isReady }">
        <div>
          <span class="dot" />
          <strong>{{ isReady ? streamStateText : receiverStateText }}</strong>
        </div>
        <span class="tag">{{ health?.version ?? 'v0.2.0' }}</span>
      </div>

      <div class="viewer-card" :class="{ active: browserHasFrames }">
        <video ref="videoElement" autoplay playsinline muted />
        <div v-if="!browserHasFrames" class="viewer-placeholder">
          <strong>{{ streamStateText }}</strong>
          <span v-if="webrtcState === 'connected'">{{ packetsReceived }} packets · {{ framesDecoded }} frames decoded</span>
          <span v-else>在 Apple 设备中打开“屏幕镜像”并选择 CastBridge</span>
        </div>
        <div class="viewer-badge">{{ webrtcState }}</div>
      </div>

      <div class="grid">
        <article>
          <span>接收器名称</span>
          <strong>{{ receiver?.receiver_name ?? ready?.receiver ?? 'CastBridge' }}</strong>
        </article>
        <article>
          <span>AirPlay Receiver</span>
          <strong>{{ receiver?.healthy ? '正常' : '未就绪' }}</strong>
        </article>
        <article>
          <span>Media Bridge</span>
          <strong>{{ media?.healthy ? media.engine : '未就绪' }}</strong>
        </article>
        <article>
          <span>视频 RTP</span>
          <strong>{{ media?.video_active ? `活跃 · ${media.buffers} buffers` : `${receiver?.video_rtp_port ?? 5000} · 等待` }}</strong>
        </article>
        <article>
          <span>浏览器接收</span>
          <strong>{{ packetsReceived }} pkt · {{ Math.round(bytesReceived / 1024) }} KiB</strong>
        </article>
        <article>
          <span>浏览器解码</span>
          <strong>{{ framesDecoded }} frames · {{ frameSize }}</strong>
        </article>
        <article>
          <span>控制面</span>
          <strong>{{ health?.status === 'ok' ? `API 正常 · ${socketState}` : '检测中' }}</strong>
        </article>
        <article>
          <span>WebRTC 信令</span>
          <strong>{{ viewerSocketState }} · {{ media?.peer_state ?? 'idle' }}</strong>
        </article>
      </div>

      <div v-if="error" class="error">{{ error }}</div>

      <div class="flow">
        <span>iPhone / iPad / Mac</span>
        <b>AirPlay</b>
        <span>UxPlay</span>
        <b>H.264 RTP</b>
        <span>GStreamer Media Bridge</span>
        <b>WebRTC</b>
        <span>Browser Video</span>
      </div>
    </section>
  </main>
</template>
