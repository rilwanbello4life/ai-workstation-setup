#!/usr/bin/env python3
"""Report what the GPU is doing, as JSON, on 127.0.0.1:8101.

The queue runs in a pod and has to decide whether there is room for another
job. It cannot ask Kubernetes, because the GPU is not managed by Kubernetes
here: Strata owns the card directly on the host and never goes through a
device plugin. So something on the host has to answer the question.

Deliberately dependency-free and read-only. It shells out to nvidia-smi and
nothing else. The whole point is that it cannot be the thing that breaks the
queue, so every failure path returns a usable answer rather than an error:
if nvidia-smi is missing or slow, callers get `available: false` and fall
back to static limits.

Installed as gpu-probe.service by server/09-gpu-queue.sh.
"""

import json
import re
import shutil
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = 8101

# nvidia-smi takes tens of milliseconds normally and can block for seconds
# when the driver is busy. The queue polls this every couple of seconds, so a
# stale-but-fast answer beats a fresh-but-late one.
CACHE_SECONDS = 1.5
QUERY_TIMEOUT = 4

_cache = {"at": 0.0, "value": None}


def _nvidia_smi():
    """One call for totals, one for per-process use. Both best effort."""
    if not shutil.which("nvidia-smi"):
        return {"available": False, "reason": "nvidia-smi not found"}

    try:
        out = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=QUERY_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return {"available": False, "reason": "nvidia-smi timed out"}
    except Exception as exc:                                  # noqa: BLE001
        return {"available": False, "reason": f"nvidia-smi failed: {exc}"}

    if out.returncode != 0:
        return {"available": False, "reason": (out.stderr or "").strip()[:200]}

    line = (out.stdout or "").strip().splitlines()
    if not line:
        return {"available": False, "reason": "no GPU reported"}

    # Only the first GPU. There is exactly one in this machine, and a second
    # would need a scheduling model this queue does not have.
    parts = [p.strip() for p in line[0].split(",")]
    try:
        util, used, total, temp = (int(float(re.sub(r"[^\d.]", "", p) or 0)) for p in parts[:4])
    except ValueError:
        return {"available": False, "reason": f"unparsable: {line[0]}"}

    data = {
        "available": True,
        "utilization_pct": util,
        "memory_used_mb": used,
        "memory_total_mb": total,
        "memory_free_mb": max(total - used, 0),
        "temperature_c": temp,
        "processes": [],
    }

    try:
        procs = subprocess.run(
            [
                "nvidia-smi",
                "--query-compute-apps=pid,process_name,used_memory",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=QUERY_TIMEOUT,
        )
        for row in (procs.stdout or "").strip().splitlines():
            bits = [b.strip() for b in row.split(",")]
            if len(bits) >= 3:
                data["processes"].append(
                    {"pid": bits[0], "name": bits[1], "memory_mb": bits[2]}
                )
    except Exception:                                          # noqa: BLE001
        # Per-process detail is informational. Totals are what admission
        # actually uses, so losing this must not fail the response.
        pass

    return data


def snapshot():
    now = time.time()
    if _cache["value"] is not None and now - _cache["at"] < CACHE_SECONDS:
        return _cache["value"]
    value = _nvidia_smi()
    value["ts"] = now
    _cache["at"] = now
    _cache["value"] = value
    return value


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):                                          # noqa: N802
        if self.path.rstrip("/") not in ("", "/gpu", "/healthz"):
            self.send_error(404)
            return
        body = json.dumps(
            {"ok": True} if self.path.rstrip("/") == "/healthz" else snapshot()
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        # Polled every two seconds forever. Logging each hit would fill the
        # journal with nothing anyone will ever read.
        pass


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
