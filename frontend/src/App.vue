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
  jitter_latency_ms?: number | null
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

type InboundVideoStats = RTCStats & {
  type: string
  kind?: string
  mediaType?: string
  codecId?: string
  packetsReceived?: number
  packetsLost?: number
  bytesReceived?: number
  framesDecoded?: number
  framesDropped?: number
  keyFramesDecoded?: number
  frameWidth?: number
  frameHeight?: number
  jitter?: number
  jitterBufferDelay?: number
  jitterBufferEmittedCount?: number
  totalDecodeTime?: number
  totalProcessingDelay?: number
  freezeCount?: number
  totalFreezesDuration?: number
  nackCount?: number
  pliCount?: number
  firCount?: number
  decoderImplementation?: string
  powerEfficientDecoder?: boolean
}

type InboundSample = {
  timestamp: number
  packetsReceived: number
  packetsLost: number
  bytesReceived: number
  framesDecoded: number
  framesDropped: number
  jitterBufferDelay: number
  jitterBufferEmittedCount: number
  totalDecodeTime: number
  totalProcessingDelay: number
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
const packetsPerSecond = ref(0)
const receiveMbps = ref(0)
const decodeFps = ref(0)
const packetsLost = ref(0)
const packetLossPercent = ref(0)
const framesDropped = ref(0)
const keyFramesDecoded = ref(0)
const jitterMs = ref(0)
const jitterBufferMs = ref(0)
const decodeMsPerFrame = ref(0)
const processingMsPerFrame = ref(0)
const freezeCount = ref(0)
const totalFreezesDuration = ref(0)
const nackCount = ref(0)
const pliCount = ref(0)
const firCount = ref(0)
const rttMs = ref(0)
const codecDescription = ref('—')
const decoderImplementation = ref('—')
const powerEfficientDecoder = ref<boolean | null>(null)
const icePath = ref('—')
const copyState = ref('复制诊断')

let socket: WebSocket | null = null
let viewerSocket: WebSocket | null = null
let peer: RTCPeerConnection | null = null
let statusTimer: number | null = null
let statsTimer: number | null = null
let viewerReconnectTimer: number | null = null
let disposed = false
let pendingCandidates: RTCIceCandidateInit[] = []
let previousInbound: InboundSample | null = null

const h264Capabilities = (() => {
  if (typeof RTCRtpReceiver === 'undefined') return [] as string[]
  return (RTCRtpReceiver.getCapabilities('video')?.codecs ?? [])
    .filter((codec) => codec.mimeType.toLowerCase() === 'video/h264')
    .map((codec) => codec.sdpFmtpLine ?? '')
    .filter(Boolean)
})()

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
const diagnosticHint = computed(() => {
  if (webrtcState.value === 'connected' && packetsReceived.value > 0 && framesDecoded.value === 0) {
    return 'RTP 已到达，但 H.264 尚未产生解码帧'
  }
  if (packetLossPercent.value >= 1) return '网络丢包偏高，优先检查 Wi-Fi / LAN 链路'
  if (jitterBufferMs.value >= 120) return '浏览器 jitter buffer 偏高，存在明显播放缓存'
  if (decodeMsPerFrame.value >= 20) return '单帧解码耗时偏高，可能存在解码性能压力'
  if (decodeFps.value > 0 && decodeFps.value < 20) return '解码帧率偏低'
  if (webrtcState.value === 'connected' && framesDecoded.value > 0) return '视频链路工作中，重点观察 FPS、buffer 和 freeze'
  return '等待 WebRTC 视频统计'
})
const diagnosticText = computed(() => JSON.stringify({
  generated_at: new Date().toISOString(),
  viewer_id: viewerId.value || null,
  browser: navigator.userAgent,
  h264_capabilities: h264Capabilities,
  webrtc: {
    state: webrtcState.value,
    signaling: viewerSocketState.value,
    ice_path: icePath.value,
    rtt_ms: Number(rttMs.value.toFixed(1)),
  },
  media_bridge: {
    state: media.value?.state ?? null,
    peer_state: media.value?.peer_state ?? null,
    streaming: media.value?.streaming ?? false,
    buffers: media.value?.buffers ?? 0,
    bytes: media.value?.bytes ?? 0,
    jitter_latency_ms: media.value?.jitter_latency_ms ?? null,
  },
  video: {
    codec: codecDescription.value,
    decoder: decoderImplementation.value,
    power_efficient_decoder: powerEfficientDecoder.value,
    resolution: frameSize.value,
    fps: Number(decodeFps.value.toFixed(1)),
    receive_mbps: Number(receiveMbps.value.toFixed(2)),
    packets_per_second: Number(packetsPerSecond.value.toFixed(0)),
    packets_received: packetsReceived.value,
    packets_lost: packetsLost.value,
    packet_loss_percent: Number(packetLossPercent.value.toFixed(2)),
    frames_decoded: framesDecoded.value,
    frames_dropped: framesDropped.value,
    keyframes_decoded: keyFramesDecoded.value,
    rtp_jitter_ms: Number(jitterMs.value.toFixed(1)),
    jitter_buffer_ms: Number(jitterBufferMs.value.toFixed(1)),
    decode_ms_per_frame: Number(decodeMsPerFrame.value.toFixed(2)),
    processing_ms_per_frame: Number(processingMsPerFrame.value.toFixed(2)),
    freeze_count: freezeCount.value,
    total_freeze_seconds: Number(totalFreezesDuration.value.toFixed(2)),
    nack_count: nackCount.value,
    pli_count: pliCount.value,
    fir_count: firCount.value,
  },
  hint: diagnosticHint.value,
}, null, 2))

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
  packetsPerSecond.value = 0
  receiveMbps.value = 0
  decodeFps.value = 0
  packetsLost.value = 0
  packetLossPercent.value = 0
  framesDropped.value = 0
  keyFramesDecoded.value = 0
  jitterMs.value = 0
  jitterBufferMs.value = 0
  decodeMsPerFrame.value = 0
  processingMsPerFrame.value = 0
  freezeCount.value = 0
  totalFreezesDuration.value = 0
  nackCount.value = 0
  pliCount.value = 0
  firCount.value = 0
  rttMs.value = 0
  codecDescription.value = '—'
  decoderImplementation.value = '—'
  powerEfficientDecoder.value = null
  icePath.value = '—'
  previousInbound = null
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
    let inbound: InboundVideoStats | null = null
    let selectedPairId: string | undefined
    let fallbackPair: RTCStats | null = null

    stats.forEach((report) => {
      const row = report as RTCStats & {
        type: string
        kind?: string
        mediaType?: string
        selectedCandidatePairId?: string
        nominated?: boolean
        state?: string
      }
      if (row.type === 'inbound-rtp' && (row.kind ?? row.mediaType) === 'video') {
        inbound = row as InboundVideoStats
      }
      if (row.type === 'transport' && row.selectedCandidatePairId) {
        selectedPairId = row.selectedCandidatePairId
      }
      if (row.type === 'candidate-pair' && row.nominated && row.state === 'succeeded') {
        fallbackPair = row
      }
    })

    if (inbound) {
      const row = inbound as InboundVideoStats
      const current: InboundSample = {
        timestamp: row.timestamp,
        packetsReceived: row.packetsReceived ?? 0,
        packetsLost: row.packetsLost ?? 0,
        bytesReceived: row.bytesReceived ?? 0,
        framesDecoded: row.framesDecoded ?? 0,
        framesDropped: row.framesDropped ?? 0,
        jitterBufferDelay: row.jitterBufferDelay ?? 0,
        jitterBufferEmittedCount: row.jitterBufferEmittedCount ?? 0,
        totalDecodeTime: row.totalDecodeTime ?? 0,
        totalProcessingDelay: row.totalProcessingDelay ?? 0,
      }

      packetsReceived.value = current.packetsReceived
      bytesReceived.value = current.bytesReceived
      framesDecoded.value = current.framesDecoded
      packetsLost.value = current.packetsLost
      framesDropped.value = current.framesDropped
      keyFramesDecoded.value = row.keyFramesDecoded ?? 0
      jitterMs.value = (row.jitter ?? 0) * 1000
      freezeCount.value = row.freezeCount ?? 0
      totalFreezesDuration.value = row.totalFreezesDuration ?? 0
      nackCount.value = row.nackCount ?? 0
      pliCount.value = row.pliCount ?? 0
      firCount.value = row.firCount ?? 0
      decoderImplementation.value = row.decoderImplementation ?? '—'
      powerEfficientDecoder.value = row.powerEfficientDecoder ?? null
      if (row.frameWidth && row.frameHeight) frameSize.value = `${row.frameWidth}×${row.frameHeight}`

      if (previousInbound && current.timestamp > previousInbound.timestamp) {
        const seconds = (current.timestamp - previousInbound.timestamp) / 1000
        const packetDelta = Math.max(0, current.packetsReceived - previousInbound.packetsReceived)
        const lostDelta = Math.max(0, current.packetsLost - previousInbound.packetsLost)
        const byteDelta = Math.max(0, current.bytesReceived - previousInbound.bytesReceived)
        const frameDelta = Math.max(0, current.framesDecoded - previousInbound.framesDecoded)
        const emittedDelta = Math.max(0, current.jitterBufferEmittedCount - previousInbound.jitterBufferEmittedCount)
        const jitterDelayDelta = Math.max(0, current.jitterBufferDelay - previousInbound.jitterBufferDelay)
        const decodeTimeDelta = Math.max(0, current.totalDecodeTime - previousInbound.totalDecodeTime)
        const processingDelayDelta = Math.max(0, current.totalProcessingDelay - previousInbound.totalProcessingDelay)

        packetsPerSecond.value = packetDelta / seconds
        receiveMbps.value = (byteDelta * 8) / seconds / 1_000_000
        decodeFps.value = frameDelta / seconds
        packetLossPercent.value = packetDelta + lostDelta > 0
          ? (lostDelta / (packetDelta + lostDelta)) * 100
          : 0
        jitterBufferMs.value = emittedDelta > 0 ? (jitterDelayDelta / emittedDelta) * 1000 : 0
        decodeMsPerFrame.value = frameDelta > 0 ? (decodeTimeDelta / frameDelta) * 1000 : 0
        processingMsPerFrame.value = frameDelta > 0 ? (processingDelayDelta / frameDelta) * 1000 : 0
      }
      previousInbound = current

      if (row.codecId) {
        const codec = stats.get(row.codecId) as (RTCStats & { mimeType?: string; sdpFmtpLine?: string }) | undefined
        if (codec) {
          codecDescription.value = [codec.mimeType, codec.sdpFmtpLine].filter(Boolean).join(' · ') || '—'
        }
      }
    }

    const pair = (selectedPairId ? stats.get(selectedPairId) : fallbackPair) as (RTCStats & {
      currentRoundTripTime?: number
      localCandidateId?: string
      remoteCandidateId?: string
      protocol?: string
    }) | undefined
    if (pair) {
      rttMs.value = (pair.currentRoundTripTime ?? 0) * 1000
      const local = pair.localCandidateId
        ? stats.get(pair.localCandidateId) as (RTCStats & { candidateType?: string; protocol?: string }) | undefined
        : undefined
      const remote = pair.remoteCandidateId
        ? stats.get(pair.remoteCandidateId) as (RTCStats & { candidateType?: string }) | undefined
        : undefined
      const protocol = pair.protocol ?? local?.protocol ?? '?'
      icePath.value = `${local?.candidateType ?? '?'} / ${protocol} → ${remote?.candidateType ?? '?'}`
    }
  } catch {
    // Peer may disappear while a reconnect is in progress.
  }
}

async function copyDiagnostic() {
  const text = diagnosticText.value
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text)
    } else {
      throw new Error('clipboard unavailable')
    }
    copyState.value = '已复制'
  } catch {
    const textarea = document.createElement('textarea')
    textarea.value = text
    textarea.style.position = 'fixed'
    textarea.style.opacity = '0'
    document.body.appendChild(textarea)
    textarea.select()
    document.execCommand('copy')
    textarea.remove()
    copyState.value = '已复制'
  }
  window.setTimeout(() => { copyState.value = '复制诊断' }, 1600)
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

      <section class="diagnostics">
        <div class="diagnostics-head">
          <div>
            <p class="eyebrow">WEBRTC DIAGNOSTICS</p>
            <h2>实时链路诊断</h2>
            <p>{{ diagnosticHint }}</p>
          </div>
          <button type="button" @click="copyDiagnostic">{{ copyState }}</button>
        </div>

        <div class="diagnostic-grid">
          <article><span>解码 FPS</span><strong>{{ decodeFps.toFixed(1) }}</strong></article>
          <article><span>接收码率</span><strong>{{ receiveMbps.toFixed(2) }} Mbps</strong></article>
          <article><span>丢包</span><strong>{{ packetLossPercent.toFixed(2) }}% · {{ packetsLost }}</strong></article>
          <article><span>丢帧</span><strong>{{ framesDropped }}</strong></article>
          <article><span>RTP Jitter</span><strong>{{ jitterMs.toFixed(1) }} ms</strong></article>
          <article><span>浏览器 Buffer</span><strong>{{ jitterBufferMs.toFixed(1) }} ms</strong></article>
          <article><span>单帧解码</span><strong>{{ decodeMsPerFrame.toFixed(2) }} ms</strong></article>
          <article><span>处理耗时</span><strong>{{ processingMsPerFrame.toFixed(2) }} ms</strong></article>
          <article><span>RTT</span><strong>{{ rttMs.toFixed(1) }} ms</strong></article>
          <article><span>关键帧</span><strong>{{ keyFramesDecoded }}</strong></article>
          <article><span>Freeze</span><strong>{{ freezeCount }} · {{ totalFreezesDuration.toFixed(1) }}s</strong></article>
          <article><span>NACK / PLI / FIR</span><strong>{{ nackCount }} / {{ pliCount }} / {{ firCount }}</strong></article>
        </div>

        <div class="diagnostic-meta">
          <span><b>Codec</b>{{ codecDescription }}</span>
          <span><b>Decoder</b>{{ decoderImplementation }}{{ powerEfficientDecoder === null ? '' : powerEfficientDecoder ? ' · HW/高效' : ' · 非高效' }}</span>
          <span><b>ICE</b>{{ icePath }}</span>
          <span><b>RTP</b>{{ packetsPerSecond.toFixed(0) }} pkt/s</span>
        </div>

        <textarea class="diagnostic-output" readonly :value="diagnosticText" aria-label="WebRTC diagnostic JSON" />
      </section>

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
