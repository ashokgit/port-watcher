from __future__ import annotations

import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Optional

from fastapi import FastAPI, Request, Response, status
from fastapi.middleware.cors import CORSMiddleware


LOG_FILE = os.environ.get("LOG_FILE", "/logs/portwatcher.log")


def ensure_log_dir(path: str) -> None:
    log_path = Path(path)
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
    except Exception as exc:  # noqa: BLE001
        print(f"[listener] Failed to create log directory: {exc}", file=sys.stderr)


ensure_log_dir(LOG_FILE)

app = FastAPI(title="Portwatcher Listener API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/healthz")
async def healthz() -> Dict[str, str]:
    return {"status": "ok"}


async def write_log_line(line: str) -> None:
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception as exc:  # noqa: BLE001
        print(f"[listener] Failed to write log: {exc}", file=sys.stderr)


# Primary ingestion endpoint. Accepts JSON or text; JSON is preferred.
@app.post("/ingest")
async def ingest(request: Request) -> Response:
    # Accept JSON or plain text lines
    content_type = request.headers.get("content-type", "").split(";")[0].strip().lower()
    ts = datetime.utcnow().isoformat() + "Z"

    if content_type == "application/json":
        try:
            body: Dict[str, Any] = await request.json()
        except Exception:
            return Response(status_code=status.HTTP_400_BAD_REQUEST, content="invalid json")
        line = json.dumps({"ts": ts, **body}, separators=(",", ":"))
        await write_log_line(line)
        return Response(status_code=status.HTTP_202_ACCEPTED)

    # Fallback to raw text
    text = await request.body()
    payload = text.decode("utf-8", errors="replace").strip()
    if not payload:
        return Response(status_code=status.HTTP_400_BAD_REQUEST, content="empty body")
    # Best-effort parse of legacy text lines into JSON-ish fields
    await write_log_line(f"{ts} {payload}")
    return Response(status_code=status.HTTP_202_ACCEPTED)


# Optional verbose endpoint to record plain lines (e.g., from curl)
@app.post("/logline")
async def log_line(request: Request) -> Dict[str, str]:
    text = await request.body()
    payload = text.decode("utf-8", errors="replace").strip()
    ts = datetime.utcnow().isoformat() + "Z"
    await write_log_line(f"{ts} {payload}")
    return {"status": "ok"}


