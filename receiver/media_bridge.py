#!/usr/bin/env python3
import asyncio
import json
import os
import signal
import time
from pathlib import Path
from typing import Any

import gi
import websockets

gi.require_version("Gst", "1.0")
gi.require_version("GstSdp", "1.0")
gi.require_version("GstWebRTC", "1.0")
from gi.repository import GLib, Gst, GstSdp, GstWebRTC  # noqa: E402

Gst.init(None)


class MediaBridge:
    def __init__(self) -> None:
        self.video_port = int(os.getenv("CASTBRIDGE_RTP_VIDEO_PORT", "5000"))
        self.jitter_latency_ms = int(os.getenv("CASTBRIDGE_RTP_JITTER_MS", "10"))
        if self.jitter_latency_ms < 0 or self.jitter_latency_ms > 1000:
            raise ValueError("CASTBRIDGE_RTP_JITTER_MS 必须在 0-1000 范围内")
        self.signaling_url = os.getenv(
            "CASTBRIDGE_WEBRTC_SIGNALING_URL",
            "ws://127.0.0.1:8090/ws/media",
        )
        run_dir = Path(os.getenv("CASTBRIDGE_RUN_DIR", "/run/castbridge"))
        self.status_file = run_dir / "media-status.json"
        self.run_dir = run_dir
        self.run_dir.mkdir(parents=True, exist_ok=True)

        # GStreamer/webrtcbin callbacks may run on streaming threads. Keep the
        # asyncio loop that owns the websocket and marshal all signaling sends
        # back onto that loop with call_soon_threadsafe().
        self.loop = asyncio.get_running_loop()
        self.websocket: Any = None
        self.pipeline: Gst.Pipeline | None = None
        self.webrtc: Gst.Element | None = None
        self.active_viewer: str | None = None
        self.last_video_at: float | None = None
        self.buffers = 0
        self.bytes = 0
        self.last_error: str | None = None
        self.signaling_connected = False
        self.running = True

    def write_status(self) -> None:
        now_mono = time.monotonic()
        video_age = None if self.last_video_at is None else max(0.0, now_mono - self.last_video_at)
        video_active = video_age is not None and video_age <= 3.0

        peer_state = "idle"
        if self.webrtc is not None:
            try:
                value = self.webrtc.get_property("connection-state")
                peer_state = getattr(value, "value_nick", str(value))
            except Exception:
                peer_state = "unknown"

        if self.last_error:
            state = "error"
        elif video_active and self.active_viewer:
            state = "streaming"
        elif self.active_viewer:
            state = "negotiating"
        elif self.signaling_connected:
            state = "waiting"
        else:
            state = "signaling_disconnected"

        payload = {
            "state": state,
            "engine": "GStreamer/webrtcbin",
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "timestamp_epoch": int(time.time()),
            "video_rtp_port": self.video_port,
            "jitter_latency_ms": self.jitter_latency_ms,
            "signaling_connected": self.signaling_connected,
            "active_viewer": self.active_viewer,
            "peer_state": peer_state,
            "video_active": video_active,
            "video_age_seconds": round(video_age, 1) if video_age is not None else None,
            "buffers": self.buffers,
            "bytes": self.bytes,
            "error": self.last_error,
        }
        tmp = self.status_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        tmp.replace(self.status_file)

    async def status_loop(self) -> None:
        context = GLib.MainContext.default()
        last_status_write = 0.0
        while self.running:
            while context.pending():
                context.iteration(False)
            self.poll_bus()
            now = time.monotonic()
            if now - last_status_write >= 1.0:
                self.write_status()
                last_status_write = now
            await asyncio.sleep(0.02)

    def poll_bus(self) -> None:
        if self.pipeline is None:
            return
        bus = self.pipeline.get_bus()
        while True:
            message = bus.pop_filtered(Gst.MessageType.ERROR | Gst.MessageType.WARNING)
            if message is None:
                break
            if message.type == Gst.MessageType.ERROR:
                error, debug = message.parse_error()
                self.last_error = f"{error}: {debug or ''}".strip()
                print(f"[media] GStreamer ERROR: {self.last_error}", flush=True)
            elif message.type == Gst.MessageType.WARNING:
                warning, debug = message.parse_warning()
                print(f"[media] GStreamer WARN: {warning}: {debug or ''}", flush=True)

    def on_video_buffer(self, _pad: Gst.Pad, info: Gst.PadProbeInfo) -> Gst.PadProbeReturn:
        buffer = info.get_buffer()
        if buffer is not None:
            self.buffers += 1
            self.bytes += buffer.get_size()
            self.last_video_at = time.monotonic()
        return Gst.PadProbeReturn.OK

    def schedule_send(self, message: dict[str, Any]) -> None:
        if self.loop.is_closed():
            return
        self.loop.call_soon_threadsafe(self._schedule_send_on_loop, message)

    def _schedule_send_on_loop(self, message: dict[str, Any]) -> None:
        if self.websocket is None:
            return
        asyncio.create_task(self.send_json(message))

    async def send_json(self, message: dict[str, Any]) -> None:
        websocket = self.websocket
        if websocket is None:
            return
        try:
            await websocket.send(json.dumps(message, ensure_ascii=False))
        except Exception as exc:
            print(f"[media] 信令发送失败: {exc}", flush=True)

    def log_sdp_video(self, label: str, sdp_text: str) -> None:
        interesting = []
        for line in sdp_text.splitlines():
            if line.startswith("m=video"):
                interesting.append(line)
            elif line.startswith("a=rtpmap:") and "H264" in line.upper():
                interesting.append(line)
            elif line.startswith("a=fmtp:"):
                interesting.append(line)
        if interesting:
            print(f"[media] {label}: {' | '.join(interesting)}", flush=True)

    def on_ice_candidate(self, _element: Gst.Element, mlineindex: int, candidate: str) -> None:
        if not self.active_viewer:
            return
        self.schedule_send(
            {
                "type": "webrtc.ice",
                "viewer_id": self.active_viewer,
                "candidate": candidate,
                "sdp_mline_index": mlineindex,
            }
        )

    def on_offer_created(self, promise: Gst.Promise, _element: Gst.Element, _data: Any) -> None:
        if self.webrtc is None or not self.active_viewer:
            return
        promise.wait()
        reply = promise.get_reply()
        offer = reply.get_value("offer") if reply is not None else None
        if offer is None:
            self.last_error = "webrtcbin 未生成 SDP offer"
            return
        offer_text = offer.sdp.as_text()
        self.log_sdp_video("SDP offer video", offer_text)
        self.webrtc.emit("set-local-description", offer, Gst.Promise.new())
        self.schedule_send(
            {
                "type": "webrtc.offer",
                "viewer_id": self.active_viewer,
                "sdp": offer_text,
            }
        )
        print(f"[media] 已向 viewer {self.active_viewer} 发送 SDP offer", flush=True)

    def on_negotiation_needed(self, element: Gst.Element) -> None:
        if not self.active_viewer:
            return
        promise = Gst.Promise.new_with_change_func(self.on_offer_created, element, None)
        element.emit("create-offer", None, promise)

    def stop_peer(self) -> None:
        if self.pipeline is not None:
            self.pipeline.set_state(Gst.State.NULL)
        self.pipeline = None
        self.webrtc = None
        self.active_viewer = None
        self.last_video_at = None
        self.last_error = None
        self.buffers = 0
        self.bytes = 0

    def start_peer(self, viewer_id: str) -> None:
        self.stop_peer()
        self.active_viewer = viewer_id
        self.last_error = None

        # UxPlay and Media Bridge run on the same host, so only a very small RTP
        # reorder window is needed. Keep the jitterbuffer for packet ordering,
        # but default it to 10 ms to avoid unnecessary playout latency.
        # H.264 remains codec-transparent: repeat SPS/PPS periodically and avoid
        # STAP-A aggregation for broad browser/hardware-decoder compatibility.
        description = (
            f'udpsrc port={self.video_port} '
            'caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96" '
            f'! rtpjitterbuffer latency={self.jitter_latency_ms} drop-on-latency=true '
            '! rtph264depay '
            '! h264parse name=parser config-interval=1 '
            '! video/x-h264,stream-format=byte-stream,alignment=au '
            '! rtph264pay pt=96 mtu=1200 config-interval=1 aggregate-mode=none '
            '! application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96,packetization-mode=(string)1 '
            '! webrtcbin name=webrtc bundle-policy=max-bundle'
        )
        pipeline = Gst.parse_launch(description)
        if not isinstance(pipeline, Gst.Pipeline):
            raise RuntimeError("无法创建 GStreamer WebRTC pipeline")

        self.pipeline = pipeline
        self.webrtc = pipeline.get_by_name("webrtc")
        parser = pipeline.get_by_name("parser")
        if self.webrtc is None or parser is None:
            raise RuntimeError("WebRTC pipeline 缺少必要元素")

        parser_pad = parser.get_static_pad("src")
        if parser_pad is not None:
            parser_pad.add_probe(Gst.PadProbeType.BUFFER, self.on_video_buffer)

        self.webrtc.connect("on-negotiation-needed", self.on_negotiation_needed)
        self.webrtc.connect("on-ice-candidate", self.on_ice_candidate)

        result = pipeline.set_state(Gst.State.PLAYING)
        if result == Gst.StateChangeReturn.FAILURE:
            raise RuntimeError("GStreamer WebRTC pipeline 启动失败")
        print(
            f"[media] viewer {viewer_id} 已连接，监听 H.264 RTP 127.0.0.1:{self.video_port}，jitter={self.jitter_latency_ms}ms",
            flush=True,
        )

    def apply_answer(self, sdp_text: str) -> None:
        if self.webrtc is None:
            return
        self.log_sdp_video("SDP answer video", sdp_text)
        result, sdp = GstSdp.SDPMessage.new()
        if result != GstSdp.SDPResult.OK:
            raise RuntimeError("无法创建 SDP message")
        parse_result = GstSdp.sdp_message_parse_buffer(sdp_text.encode("utf-8"), sdp)
        if parse_result != GstSdp.SDPResult.OK:
            raise RuntimeError("浏览器 SDP answer 解析失败")
        answer = GstWebRTC.WebRTCSessionDescription.new(GstWebRTC.WebRTCSDPType.ANSWER, sdp)
        self.webrtc.emit("set-remote-description", answer, Gst.Promise.new())
        print(f"[media] viewer {self.active_viewer} SDP answer 已应用", flush=True)

    def add_ice_candidate(self, mlineindex: int, candidate: str) -> None:
        if self.webrtc is not None:
            self.webrtc.emit("add-ice-candidate", mlineindex, candidate)

    async def handle_message(self, raw: str) -> None:
        message = json.loads(raw)
        message_type = message.get("type")
        viewer_id = message.get("viewer_id")

        if message_type == "viewer.connected" and isinstance(viewer_id, str):
            try:
                self.start_peer(viewer_id)
            except Exception as exc:
                self.last_error = str(exc)
                print(f"[media] 创建 WebRTC peer 失败: {exc}", flush=True)
        elif message_type == "viewer.disconnected" and viewer_id == self.active_viewer:
            print(f"[media] viewer {viewer_id} 已断开", flush=True)
            self.stop_peer()
        elif message_type == "webrtc.answer" and viewer_id == self.active_viewer:
            sdp = message.get("sdp")
            if isinstance(sdp, str):
                self.apply_answer(sdp)
        elif message_type == "webrtc.ice" and viewer_id == self.active_viewer:
            candidate = message.get("candidate")
            mlineindex = message.get("sdp_mline_index")
            if isinstance(candidate, str) and isinstance(mlineindex, int):
                self.add_ice_candidate(mlineindex, candidate)

    async def signaling_loop(self) -> None:
        while self.running:
            try:
                print(f"[media] 连接信令: {self.signaling_url}", flush=True)
                async with websockets.connect(
                    self.signaling_url,
                    ping_interval=20,
                    ping_timeout=20,
                    close_timeout=5,
                ) as websocket:
                    self.websocket = websocket
                    self.signaling_connected = True
                    self.last_error = None
                    print("[media] WebRTC 信令已连接", flush=True)
                    async for raw in websocket:
                        await self.handle_message(raw)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                print(f"[media] 信令断开: {exc}", flush=True)
            finally:
                self.websocket = None
                self.signaling_connected = False
                self.stop_peer()
                self.write_status()
            if self.running:
                await asyncio.sleep(2)

    async def run(self) -> None:
        print(
            f"[media] CastBridge Media Bridge 启动，video RTP={self.video_port}，jitter={self.jitter_latency_ms}ms",
            flush=True,
        )
        status_task = asyncio.create_task(self.status_loop())
        try:
            await self.signaling_loop()
        finally:
            self.running = False
            status_task.cancel()
            self.stop_peer()
            self.write_status()
            try:
                await status_task
            except asyncio.CancelledError:
                pass


async def main() -> None:
    bridge = MediaBridge()
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def request_stop() -> None:
        bridge.running = False
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, request_stop)
        except NotImplementedError:
            pass

    task = asyncio.create_task(bridge.run())
    stop_task = asyncio.create_task(stop_event.wait())
    done, pending = await asyncio.wait(
        {task, stop_task},
        return_when=asyncio.FIRST_COMPLETED,
    )
    for pending_task in pending:
        pending_task.cancel()
    if task in done:
        await task
    else:
        bridge.running = False
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass


if __name__ == "__main__":
    asyncio.run(main())
