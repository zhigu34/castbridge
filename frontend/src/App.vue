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
  environment: string
}

const health = ref<Health | null>(null)
const ready = ref<Ready | null>(null)
const error = ref('')
const socketState = ref<'连接中' | '已连接' | '未连接'>('连接中')
let socket: WebSocket | null = null

const isReady = computed(() => health.value?.status === 'ok' && ready.value?.ready === true)

async function loadStatus() {
  try {
    error.value = ''
    const [healthResponse, readyResponse] = await Promise.all([
      fetch('/api/health'),
      fetch('/api/ready'),
    ])
    if (!healthResponse.ok || !readyResponse.ok) throw new Error('后端状态请求失败')
    health.value = await healthResponse.json()
    ready.value = await readyResponse.json()
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
  connectSocket()
})

onBeforeUnmount(() => socket?.close())
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
        当前为 M0 工程基础阶段。下一步将接入 AirPlay Receiver，并把实时画面桥接到 WebRTC。
      </p>

      <div class="status-card" :class="{ ready: isReady }">
        <div>
          <span class="dot" />
          <strong>{{ isReady ? '系统已就绪' : '正在检查系统状态' }}</strong>
        </div>
        <span class="tag">{{ health?.version ?? 'v0.1.0' }}</span>
      </div>

      <div class="grid">
        <article>
          <span>接收器名称</span>
          <strong>{{ ready?.receiver ?? 'CastBridge' }}</strong>
        </article>
        <article>
          <span>API</span>
          <strong>{{ health?.status === 'ok' ? '正常' : '检测中' }}</strong>
        </article>
        <article>
          <span>WebSocket</span>
          <strong>{{ socketState }}</strong>
        </article>
        <article>
          <span>运行环境</span>
          <strong>{{ ready?.environment ?? 'production' }}</strong>
        </article>
      </div>

      <div v-if="error" class="error">{{ error }}</div>

      <div class="flow">
        <span>iPhone / iPad / Mac</span>
        <b>AirPlay</b>
        <span>CastBridge</span>
        <b>WebRTC</b>
        <span>Browser</span>
      </div>
    </section>
  </main>
</template>
