#!/usr/bin/env python3
"""Local YouTube -> CC:Tweaked converter (DFPWM audio + NFP cover)."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from PIL import Image

try:
    import yt_dlp
except ImportError:
    yt_dlp = None

ROOT = Path(__file__).resolve().parent
JOBS = ROOT / "jobs"
JOBS.mkdir(exist_ok=True)
PORT = 8765

CC_PALETTE = [
    (240, 240, 240),
    (242, 178, 51),
    (229, 127, 216),
    (153, 178, 242),
    (222, 222, 108),
    (127, 204, 25),
    (242, 178, 204),
    (76, 76, 76),
    (153, 153, 153),
    (76, 153, 178),
    (178, 102, 229),
    (51, 102, 204),
    (127, 102, 76),
    (87, 166, 78),
    (204, 76, 76),
    (17, 17, 17),
]
HEX = "0123456789abcdef"
VIDEO_ID_RE = re.compile(
    r"(?:youtu\.be/|v=|shorts/)([A-Za-z0-9_-]{11})"
)

JOB_LOCK = threading.Lock()
JOB_STATE: dict[str, dict] = {}


def video_id(url: str) -> str | None:
    m = VIDEO_ID_RE.search(url)
    return m.group(1) if m else None


def nearest_cc(rgb: tuple[int, int, int]) -> int:
    r, g, b = rgb
    best_i, best_d = 0, 10**9
    for i, (pr, pg, pb) in enumerate(CC_PALETTE):
        d = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2
        if d < best_d:
            best_i, best_d = i, d
    return best_i


def image_to_nfp(img: Image.Image, w: int, h: int) -> str:
    w = max(8, min(w, 164))
    h = max(4, min(h, 81))
    img = img.convert("RGB").resize((w, h), Image.Resampling.LANCZOS)
    lines = []
    px = img.load()
    for y in range(h):
        row = []
        for x in range(w):
            row.append(HEX[nearest_cc(px[x, y])])
        lines.append("".join(row))
    return "\n".join(lines) + "\n"


def set_job(job_id: str, **fields) -> None:
    with JOB_LOCK:
        JOB_STATE.setdefault(job_id, {})
        JOB_STATE[job_id].update(fields)


def get_job(job_id: str) -> dict | None:
    with JOB_LOCK:
        data = JOB_STATE.get(job_id)
        return dict(data) if data else None


def fetch_cover(vid: str, dest: Path) -> None:
    urls = [
        f"https://i.ytimg.com/vi/{vid}/maxresdefault.jpg",
        f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg",
        f"https://i.ytimg.com/vi/{vid}/mqdefault.jpg",
    ]
    import urllib.request

    for u in urls:
        try:
            urllib.request.urlretrieve(u, dest)
            if dest.stat().st_size > 1000:
                return
        except Exception:
            continue
    raise RuntimeError("Could not download thumbnail")


def convert_job(job_id: str, url: str, cover_w: int, cover_h: int) -> None:
    job_dir = JOBS / job_id
    job_dir.mkdir(exist_ok=True)
    nfp_path = job_dir / "cover.nfp"
    dfpwm_path = job_dir / "audio.dfpwm"
    wav_path = job_dir / "audio.wav"

    try:
        set_job(job_id, status="working", phase="title", message="Fetching title")
        if yt_dlp is None:
            raise RuntimeError("yt-dlp is not installed")

        ydl_opts = {
            "quiet": True,
            "no_warnings": True,
            "skip_download": True,
            "noplaylist": True,
        }
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=False)
        title = info.get("title") or "Unknown title"
        vid = info.get("id") or video_id(url) or "unknown"
        duration = int(info.get("duration") or 0)
        if duration > 15 * 60:
            raise RuntimeError("Video is longer than 15 minutes")
        set_job(job_id, title=title, video_id=vid, phase="cover", message="Making cover art")

        jpg = job_dir / "cover.jpg"
        fetch_cover(vid, jpg)
        with Image.open(jpg) as im:
            nfp_path.write_text(image_to_nfp(im, cover_w, cover_h), encoding="ascii")
        set_job(
            job_id,
            phase="audio",
            message="Converting audio to DFPWM",
            cover="/files/" + job_id + "/cover.nfp",
        )

        audio_opts = {
            "quiet": True,
            "no_warnings": True,
            "noplaylist": True,
            "format": "bestaudio/best",
            "outtmpl": str(job_dir / "raw.%(ext)s"),
        }
        with yt_dlp.YoutubeDL(audio_opts) as ydl:
            ydl.download([url])

        raw = next(
            (
                p
                for p in job_dir.iterdir()
                if p.suffix.lower() in {".webm", ".m4a", ".opus", ".mp3", ".ogg", ".wav", ".mkv"}
                and p.name.startswith("raw.")
            ),
            None,
        )
        if raw is None:
            raise RuntimeError("yt-dlp did not produce an audio file")

        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            raise RuntimeError("ffmpeg is not installed")
        subprocess.check_call(
            [
                ffmpeg,
                "-y",
                "-i",
                str(raw),
                "-ac",
                "1",
                "-ar",
                "48000",
                "-c:a",
                "dfpwm",
                str(dfpwm_path),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        raw.unlink(missing_ok=True)
        wav_path.unlink(missing_ok=True)

        set_job(
            job_id,
            status="ready",
            phase="done",
            message="Ready",
            cover="/files/" + job_id + "/cover.nfp",
            audio="/files/" + job_id + "/audio.dfpwm",
        )
    except Exception as exc:
        set_job(job_id, status="error", message=str(exc), error=str(exc))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        print("[ytcc] " + (fmt % args))

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _file(self, path: Path, content_type: str) -> None:
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/health"):
            self._json(200, {"ok": True, "service": "ytcc"})
            return
        if parsed.path.startswith("/job/"):
            job_id = parsed.path.split("/")[2]
            job = get_job(job_id)
            if not job:
                self._json(404, {"status": "error", "error": "unknown job"})
                return
            self._json(200, job)
            return
        if parsed.path.startswith("/files/"):
            parts = parsed.path.split("/")
            # /files/<id>/cover.nfp
            if len(parts) < 4:
                self._json(404, {"error": "not found"})
                return
            job_id, name = parts[2], parts[3]
            if name not in {"cover.nfp", "audio.dfpwm"}:
                self._json(404, {"error": "not found"})
                return
            path = JOBS / job_id / name
            if not path.is_file():
                self._json(404, {"error": "not ready"})
                return
            ctype = "text/plain" if name.endswith(".nfp") else "application/octet-stream"
            self._file(path, ctype)
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path != "/job":
            self._json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            qs = parse_qs(raw.decode("utf-8"))
            payload = {k: v[0] for k, v in qs.items()}
        url = (payload.get("url") or "").strip()
        if not url:
            self._json(400, {"status": "error", "error": "missing url"})
            return
        cover_w = int(payload.get("w") or 80)
        cover_h = int(payload.get("h") or 24)
        job_id = uuid.uuid4().hex[:12]
        set_job(
            job_id,
            id=job_id,
            status="working",
            phase="queued",
            message="Queued",
            title="...",
            url=url,
        )
        threading.Thread(
            target=convert_job,
            args=(job_id, url, cover_w, cover_h),
            daemon=True,
        ).start()
        self._json(200, {"id": job_id, "status": "working"})


def guess_urls() -> list[str]:
    urls = [f"http://127.0.0.1:{PORT}"]
    try:
        import socket

        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("1.1.1.1", 80))
        lan = s.getsockname()[0]
        s.close()
        urls.append(f"http://{lan}:{PORT}")
    except Exception:
        pass
    try:
        out = subprocess.check_output(["tailscale", "ip", "-4"], text=True).strip()
        if out:
            urls.append(f"http://{out.split()[0]}:{PORT}")
    except Exception:
        pass
    return urls


def main() -> None:
    if shutil.which("ffmpeg") is None:
        raise SystemExit("ffmpeg is required")
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("ytcc converter ready")
    print("From the ComputerCraft computer use the Tailscale URL if LAN is blocked:")
    for u in guess_urls():
        print("  " + u)
    print("Health check: /health")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
