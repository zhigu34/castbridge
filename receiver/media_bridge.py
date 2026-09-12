#!/usr/bin/env python3
import asyncio
import base64
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

RTP_CLOCK_RATE = 90000.0
NANOSECONDS = 1_000_000_000.0
MIN_RTP_CLOCK_CHANGES = 8
MIN_RTP_CLOCK_SECONDS = 1.0
OFFER_PROFILE_WAIT_SECONDS = 1.5


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

        self.loop = asyncio.get_running_loop()
        self.websocket: Any = None
        self.pipeline: Gst.Pipeline | None = None
        self.webrtc: Gst.Element | None = None
        self.au_src: Gst.Element | None = None
        self.active_viewer: str | None = None
        self.last_video_at: float | None = None
        self.buffers = 0
        self.bytes = 0
        self.input_fps = 0.0
        self.input_mbps = 0.0
        self.rate_sample_at = time.monotonic()
        self.rate_sample_buffers = 0
        self.rate_sample_bytes = 0
        self.retimed_au_buffers = 0
        self.retime_push_failures = 0
        self.source_idr_count = 0
        self.source_sps_count = 0
        self.source_pps_count = 0
        self.source_profile_level_id: str | None = None
        self.source_sps_b64: str | None = None
        self.source_pps_b64: str | None = None
        self.offer_profile_level_id: str | None = None
        self.last_idr_at: float | None = None
        self.force_key_unit_events = 0
        self.offer_pending = False
        self.offer_in_progress = False
        self.offer_timeout_task: asyncio.Task[None] | None = None
        self.last_error: str | None = None
        self.signaling_connected = False
        self.running = True
        self.reset_clock_metrics()

    def reset_clock_metrics(self) -> None:
        self.input_rtp_first_ts: int | None = None
        self.input_rtp_last_ts: int | None = None
        self.input_rtp_first_at: float | None = None
        self.input_rtp_clock_ratio = 0.0
        self.input_rtp_timestamp_changes = 0

        self.output_rtp_first_ts: int | None = None
        self.output_rtp_last_ts: int | None = None
        self.output_rtp_first_at: float | None = None
        self.output_rtp_clock_ratio = 0.0
        self.output_rtp_timestamp_changes = 0

        self.parser_first_pts: int | None = None
        self.parser_first_at: float | None = None
        self.parser_pts_clock_ratio = 0.0
        self.parser_pts_valid_buffers = 0

    @staticmethod
    def rtp_timestamp(buffer: Gst.Buffer) -> int | None:
        if buffer.get_size() < 12:
            return None
        header = buffer.extract_dup(0, 12)
        if len(header) < 12 or (header[0] >> 6) != 2:
            return None
        return int.from_bytes(header[4:8], "big")

    @staticmethod
    def h264_nals(buffer: Gst.Buffer) -> list[bytes]:
        data = buffer.extract_dup(0, buffer.get_size())
        boundaries: list[tuple[int, int]] = []
        index = 0
        length = len(data)
        while index + 3 < length:
            if data[index : index + 3] == b"\x00\x00\x01":
                boundaries.append((index, index + 3))
                index += 3
                continue
            if index + 4 <= length and data[index : index + 4] == b"\x00\x00\x00\x01":
                boundaries.append((index, index + 4))
                index += 4
                continue
            index += 1

        nals: list[bytes] = []
        for idx, (_start_code, nal_start) in enumerate(boundaries):
            nal_end = boundaries[idx + 1][0] if idx + 1 < len(boundaries) else length
            if nal_start < nal_end:
                nals.append(data[nal_start:nal_end])
        return nals

    def update_rtp_clock(self, direction: str, timestamp: int, now: float) -> None:
        first_ts_name = f"{direction}_rtp_first_ts"
        last_ts_name = f"{direction}_rtp_last_ts"
        first_at_name = f"{direction}_rtp_first_at"
        ratio_name = f"{direction}_rtp_clock_ratio"
        changes_name = f"{direction}_rtp_timestamp_changes"

        first_ts = getattr(self, first_ts_name)
        if first_ts is None:
            setattr(self, first_ts_name, timestamp)
            setattr(self, last_ts_name, timestamp)
            setattr(self, first_at_name, now)
            return

        last_ts = getattr(self, last_ts_name)
        if timestamp == last_ts:
            return

        setattr(self, last_ts_name, timestamp)
        changes = getattr(self, changes_name) + 1
        setattr(self, changes_name, changes)
        first_at = getattr(self, first_at_name)
        if first_at is None or now <= first_at:
            return

        wall_seconds = now - first_at
        if changes < MIN_RTP_CLOCK_CHANGES or wall_seconds < MIN_RTP_CLOCK_SECONDS:
            return

        ticks = (timestamp - first_ts) & 0xFFFFFFFF
        rtp_seconds = ticks / RTP_CLOCK_RATE
        setattr(self, ratio_name, rtp_seconds / wall_seconds)

    def update_parser_pts(self, pts: int, now: float) -> None:
        if pts == Gst.CLOCK_TIME_NONE:
            return
        self.parser_pts_valid_buffers += 1
        if self.parser_first_pts is None:
            self.parser_first_pts = pts
            self.parser_first_at = now
            return
        if self.parser_first_at is None or now <= self.parser_first_at:
            return
        pts_seconds = max(0.0, (pts - self.parser_first_pts) / NANOSECONDS)
        wall_seconds = now - self.parser_first_at
        self.parser_pts_clock_ratio = pts_seconds / wall_seconds

    def update_input_rate(self, now: float) -> None:
        elapsed = now - self.rate_sample_at
        if elapsed <= 0:
            return
        buffer_delta = max(0, self.buffers - self.rate_sample_buffers)
        byte_delta = max(0, self.bytes - self.rate_sample_bytes)
        self.input_fps = buffer_delta / elapsed
        self.input_mbps = (byte_delta * 8) / elapsed / 1_000_000
        self.rate_sample_at = now
        self.rate_sample_buffers = self.buffers
        self.rate_sample_bytes = self.bytes

    def write_status(self) -> None:
        now_mono = time.monotonic()
        video_age = None if self.last_video_at is None else max(0.0, now_mono - self.last_video_at)
        video_active = video_age is not None and video_age <= 3.0
        last_idr_age = None if self.last_idr_at is None else max(0.0, now_mono - self.last_idr_at)

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
            "retime_mode": "h264-au-arrival-clock",
            "retimed_au_buffers": self.retimed_au_buffers,
            "retime_push_failures": self.retime_push_failures,
            "source_idr_count": self.source_idr_count,
            "source_sps_count": self.source_sps_count,
            "source_pps_count": self.source_pps_count,
            "source_profile_level_id": self.source_profile_level_id,
            "offer_profile_level_id": self.offer_profile_level_id,
            "last_idr_age_seconds": round(last_idr_age, 1) if last_idr_age is not None else None,
            "force_key_unit_events": self.force_key_unit_events,
            "input_fps": round(self.input_fps, 1),
            "input_mbps": round(self.input_mbps, 3),
            "input_rtp_clock_ratio": round(self.input_rtp_clock_ratio, 4),
            "output_rtp_clock_ratio": round(self.output_rtp_clock_ratio, 4),
            "parser_pts_clock_ratio": round(self.parser_pts_clock_ratio, 4),
            "input_rtp_timestamp_changes": self.input_rtp_timestamp_changes,
            "output_rtp_timestamp_changes": self.output_rtp_timestamp_changes,
            "parser_pts_valid_buffers": self.parser_pts_valid_buffers,
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
                self.update_input_rate(now)
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

    def on_input_rtp(self, _pad: Gst.Pad, info: Gst.PadProbeInfo) -> Gst.PadProbeReturn:
        buffer = info.get_buffer()
        if buffer is not None:
            timestamp = self.rtp_timestamp(buffer)
            if timestamp is not None:
                self.update_rtp_clock("input", timestamp, time.monotonic())
        return Gst.PadProbeReturn.OK

    def on_output_rtp(self, _pad: Gst.Pad, info: Gst.PadProbeInfo) -> Gst.PadProbeReturn:
        buffer = info.get_buffer()
        if buffer is not None:
            timestamp = self.rtp_timestamp(buffer)
            if timestamp is not None:
                self.update_rtp_clock("output", timestamp, time.monotonic())
        return Gst.PadProbeReturn.OK

    def on_force_key_unit_event(self, _pad: Gst.Pad, info: Gst.PadProbeInfo) -> Gst.PadProbeReturn:
        event = info.get_event()
        if event is None:
            return Gst.PadProbeReturn.OK
        structure = event.get_structure()
        if structure is None or structure.get_name() != "GstForceKeyUnit":
            return Gst.PadProbeReturn.OK

        self.force_key_unit_events += 1
        if self.force_key_unit_events <= 5 or self.force_key_unit_events % 100 == 0:
            print(
                f"[media] 收到上游 GstForceKeyUnit #{self.force_key_unit_events}",
                flush=True,
            )
        return Gst.PadProbeReturn.OK

    def on_retimed_video_buffer(self, _pad: Gst.Pad, info: Gst.PadProbeInfo) -> Gst.PadProbeReturn:
        buffer = info.get_buffer()
        if buffer is not None:
            self.update_parser_pts(buffer.pts, time.monotonic())
        return Gst.PadProbeReturn.OK

    def remember_h264_parameters(self, nals: list[bytes]) -> None:
        profile_changed = False
        for nal in nals:
            if not nal:
                continue
            nal_type = nal[0] & 0x1F
            if nal_type == 7 and len(nal) >= 4:
                profile_level_id = f"{nal[1]:02x}{nal[2]:02x}{nal[3]:02x}"
                self.source_sps_b64 = base64.b64encode(nal).decode("ascii")
                if profile_level_id != self.source_profile_level_id:
                    self.source_profile_level_id = profile_level_id
                    profile_changed = True
                    print(
                        f"[media] H.264 source profile-level-id={profile_level_id}",
                        flush=True,
                    )
            elif nal_type == 8:
                self.source_pps_b64 = base64.b64encode(nal).decode("ascii")

        if profile_changed and self.offer_pending:
            self.loop.call_soon_threadsafe(self._maybe_create_offer, False)

    def on_au_sample(self, sink: Gst.Element) -> Gst.FlowReturn:
        sample = sink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.EOS
        buffer = sample.get_buffer()
        au_src = self.au_src
        if buffer is None or au_src is None:
            return Gst.FlowReturn.OK

        now = time.monotonic()
        self.buffers += 1
        self.bytes += buffer.get_size()
        self.last_video_at = now

        nals = self.h264_nals(buffer)
        nal_types = [(nal[0] & 0x1F) for nal in nals if nal]
        idr_count = nal_types.count(5)
        if idr_count:
            self.source_idr_count += idr_count
            self.last_idr_at = now
        self.source_sps_count += nal_types.count(7)
        self.source_pps_count += nal_types.count(8)
        self.remember_h264_parameters(nals)

        # Keep the RTP reorder window so fragmented H.264 reaches us as complete
        # access units. The source RTP timeline is unreliable, so retime only
        # after a full AU exists. The appsink is deliberately non-dropping:
        # silently dropping one predictive AU can poison the reference chain
        # until the next IDR.
        out_buffer = buffer.copy_deep()
        out_buffer.pts = Gst.CLOCK_TIME_NONE
        out_buffer.dts = Gst.CLOCK_TIME_NONE
        out_buffer.duration = Gst.CLOCK_TIME_NONE
        flow = au_src.emit("push-buffer", out_buffer)
        if flow == Gst.FlowReturn.OK:
            self.retimed_au_buffers += 1
        else:
            self.retime_push_failures += 1
            if self.retime_push_failures <= 5:
                print(f"[media] AU retime push failed: {flow}", flush=True)
        return Gst.FlowReturn.OK

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

    def configure_h264_codec_preferences(self) -> None:
        if self.webrtc is None or self.source_profile_level_id is None:
            return
        transceiver = self.webrtc.emit("get-transceiver", 0)
        if transceiver is None:
            print("[media] 未找到 WebRTC video transceiver，跳过 H.264 profile preference", flush=True)
            return

        fields = [
            "application/x-rtp",
            "media=(string)video",
            "encoding-name=(string)H264",
            "clock-rate=(int)90000",
            "payload=(int)96",
            "packetization-mode=(string)1",
            "level-asymmetry-allowed=(string)1",
            f"profile-level-id=(string){self.source_profile_level_id}",
        ]
        if self.source_sps_b64 and self.source_pps_b64:
            fields.append(
                f'sprop-parameter-sets=(string)"{self.source_sps_b64},{self.source_pps_b64}"'
            )
        caps = Gst.Caps.from_string(",".join(fields))
        transceiver.set_property("codec-preferences", caps)
        self.offer_profile_level_id = self.source_profile_level_id
        print(
            f"[media] WebRTC H.264 codec preference profile-level-id={self.offer_profile_level_id}",
            flush=True,
        )

    async def _offer_after_timeout(self) -> None:
        try:
            await asyncio.sleep(OFFER_PROFILE_WAIT_SECONDS)
            self._maybe_create_offer(True)
        except asyncio.CancelledError:
            raise
        finally:
            self.offer_timeout_task = None

    def _maybe_create_offer(self, force: bool = False) -> None:
        if self.webrtc is None or not self.active_viewer or not self.offer_pending:
            return
        if self.offer_in_progress:
            return

        if self.source_profile_level_id is None and not force:
            if self.offer_timeout_task is None:
                self.offer_timeout_task = asyncio.create_task(self._offer_after_timeout())
            return

        if self.offer_timeout_task is not None:
            self.offer_timeout_task.cancel()
            self.offer_timeout_task = None

        if self.source_profile_level_id is not None:
            self.configure_h264_codec_preferences()
        else:
            print(
                "[media] 等待源 SPS 超时，使用通用 H.264 codec preference 生成 offer",
                flush=True,
            )

        self.offer_pending = False
        self.offer_in_progress = True
        promise = Gst.Promise.new_with_change_func(self.on_offer_created, self.webrtc, None)
        self.webrtc.emit("create-offer", None, promise)

    def _offer_finished(self) -> None:
        self.offer_in_progress = False

    def on_offer_created(self, promise: Gst.Promise, _element: Gst.Element, _data: Any) -> None:
        self.loop.call_soon_threadsafe(self._offer_finished)
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

    def on_negotiation_needed(self, _element: Gst.Element) -> None:
        if not self.active_viewer:
            return
        self.offer_pending = True
        self.loop.call_soon_threadsafe(self._maybe_create_offer, False)

    def stop_peer(self) -> None:
        if self.offer_timeout_task is not None:
            self.offer_timeout_task.cancel()
            self.offer_timeout_task = None
        if self.pipeline is not None:
            self.pipeline.set_state(Gst.State.NULL)
        self.pipeline = None
        self.webrtc = None
        self.au_src = None
        self.active_viewer = None
        self.last_video_at = None
        self.last_error = None
        self.buffers = 0
        self.bytes = 0
        self.input_fps = 0.0
        self.input_mbps = 0.0
        self.rate_sample_at = time.monotonic()
        self.rate_sample_buffers = 0
        self.rate_sample_bytes = 0
        self.retimed_au_buffers = 0
        self.retime_push_failures = 0
        self.source_idr_count = 0
        self.source_sps_count = 0
        self.source_pps_count = 0
        self.source_profile_level_id = None
        self.source_sps_b64 = None
        self.source_pps_b64 = None
        self.offer_profile_level_id = None
        self.last_idr_at = None
        self.force_key_unit_events = 0
        self.offer_pending = False
        self.offer_in_progress = False
        self.reset_clock_metrics()

    def start_peer(self, viewer_id: str) -> None:
        self.stop_peer()
        self.active_viewer = viewer_id
        self.last_error = None

        description = (
            f'udpsrc name=rtpin port={self.video_port} '
            'caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96" '
            f'! rtpjitterbuffer latency={self.jitter_latency_ms} drop-on-latency=true '
            '! rtph264depay '
            '! h264parse name=source_parser config-interval=1 '
            '! video/x-h264,stream-format=byte-stream,alignment=au '
            '! appsink name=au_sink emit-signals=true sync=false max-buffers=4 drop=false '
            'appsrc name=au_src is-live=true format=time do-timestamp=true block=false '
            'caps="video/x-h264,stream-format=byte-stream,alignment=au" '
            '! h264parse name=parser config-interval=1 '
            '! video/x-h264,stream-format=byte-stream,alignment=au '
            '! rtph264pay name=pay pt=96 mtu=1200 config-interval=1 aggregate-mode=none '
            '! application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96,packetization-mode=(string)1 '
            '! webrtcbin name=webrtc bundle-policy=max-bundle'
        )
        pipeline = Gst.parse_launch(description)
        if not isinstance(pipeline, Gst.Pipeline):
            raise RuntimeError("无法创建 GStreamer WebRTC pipeline")

        self.pipeline = pipeline
        self.webrtc = pipeline.get_by_name("webrtc")
        self.au_src = pipeline.get_by_name("au_src")
        rtpin = pipeline.get_by_name("rtpin")
        au_sink = pipeline.get_by_name("au_sink")
        parser = pipeline.get_by_name("parser")
        pay = pipeline.get_by_name("pay")
        if (
            self.webrtc is None
            or self.au_src is None
            or rtpin is None
            or au_sink is None
            or parser is None
            or pay is None
        ):
            raise RuntimeError("WebRTC pipeline 缺少必要元素")

        input_pad = rtpin.get_static_pad("src")
        if input_pad is not None:
            input_pad.add_probe(Gst.PadProbeType.BUFFER, self.on_input_rtp)
        parser_pad = parser.get_static_pad("src")
        if parser_pad is not None:
            parser_pad.add_probe(Gst.PadProbeType.BUFFER, self.on_retimed_video_buffer)
        output_pad = pay.get_static_pad("src")
        if output_pad is not None:
            output_pad.add_probe(Gst.PadProbeType.BUFFER, self.on_output_rtp)
        pay_sink_pad = pay.get_static_pad("sink")
        if pay_sink_pad is not None:
            pay_sink_pad.add_probe(Gst.PadProbeType.EVENT_UPSTREAM, self.on_force_key_unit_event)
        au_sink.connect("new-sample", self.on_au_sample)

        self.webrtc.connect("on-negotiation-needed", self.on_negotiation_needed)
        self.webrtc.connect("on-ice-candidate", self.on_ice_candidate)

        result = pipeline.set_state(Gst.State.PLAYING)
        if result == Gst.StateChangeReturn.FAILURE:
            raise RuntimeError("GStreamer WebRTC pipeline 启动失败")
        print(
            f"[media] viewer {viewer_id} 已连接，RTP reorder={self.jitter_latency_ms}ms，retime=h264-au-arrival-clock，AU drop=off",
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
            f"[media] CastBridge Media Bridge 启动，video RTP={self.video_port}，reorder={self.jitter_latency_ms}ms，retime=h264-au-arrival-clock，AU drop=off",
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
