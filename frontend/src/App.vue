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

const health = ref<Health | null>(null)
const ready = ref<Ready | null>(null)
const receiver = ref<Receiver | null>(null)
const error = ref('')
const socketState = ref<'连接中' | '已连接' | '未连接'>('连接中')
let socket: WebSocket | null = null
let statusTimer: number | null = null

const isReady = computed(() => health.value?.status === 'ok' && receiver.value?.healthy === true)
const receiverStateText = computed(() => {
  if (!receiver.value) return '检测中'
  if (receiver.value.healthy) return 'AirPlay 已就绪'
  if (receiver.value.state === 'unavailable') return 'Receiver 未启动'
  if (receiver.value.state === 'stopped') return 'Receiver 已停止'
  return receiver.value.message || receiver.value.state
})

async function loadStatus() {
  try {
    error.value = ''
    const [healthResponse, readyResponse, receiverResponse] = await Promise.all([
      fetch('/api/health'),
      fetch('/api/ready'),
      fetch('/api/v1/receiver'),
    ])
    if (!healthResponse.ok || !readyResponse.ok || !receiverResponse.ok) {
      throw new Error('后端状态请求失败')
    }
    health.value = await healthResponse.json()
    ready.value = await readyResponse.json()
    receiver.value = await receiverResponse.json()
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

onMounted(() => {
  void loadStatus()
  statusTimer = window.setInterval(() => void loadStatus(), 3000)
  connectSocket()
})

onBeforeUnmount(() => {
  socket?.close()
  if (statusTimer !== null) window.clearInterval(statusTimer)
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
        当前进入 M1 AirPlay 接入验证。请在 iPhone / iPad / Mac 的“屏幕镜像”中查找下方接收器名称。
      </p>

      <div class="status-card" :class="{ ready: isReady }">
        <div>
          <span class="dot" />
          <strong>{{ isReady ? 'AirPlay Receiver 已就绪' : receiverStateText }}</strong>
        </div>
        <span class="tag">{{ health?.version ?? 'v0.1.0' }}</span>
      </div>

      <div class="grid">
        <article>
          <span>接收器名称</span>
          <strong>{{ receiver?.receiver_name ?? ready?.receiver ?? 'CastBridge' }}</strong>
        </article>
        <article>
          <span>Receiver</span>
          <strong>{{ receiver?.healthy ? '正常' : '未就绪' }}</strong>
        </article>
        <article>
          <span>接收引擎</span>
          <strong>{{ receiver?.engine ?? 'UxPlay' }} {{ receiver?.engine_version ?? '' }}</strong>
        </article>
        <article>
          <span>AirPlay 端口</span>
          <strong>{{ receiver?.airplay_port ? `${receiver.airplay_port}-${receiver.airplay_port + 2}` : '检测中' }}</strong>
        </article>
        <article>
          <span>API / WebSocket</span>
          <strong>{{ health?.status === 'ok' ? `正常 · ${socketState}` : '检测中' }}</strong>
        </article>
        <article>
          <span>RTP 预留输出</span>
          <strong>{{ receiver?.video_rtp_port ?? '-' }} / {{ receiver?.audio_rtp_port ?? '-' }}</strong>
        </article>
      </div>

      <div v-if="error" class="error">{{ error }}</div>

      <div class="flow">
        <span>iPhone / iPad / Mac</span>
        <b>AirPlay</b>
        <span>UxPlay Receiver</span>
        <b>RTP</b>
        <span>Media Bridge（下一步）</span>
        <b>WebRTC</b>
        <span>Browser</span>
      </div>
    </section>
  </main>
</template>
