# Python tester

Run a simple Python TCP/HTTP server inside the container to generate open/close events that the watcher forwards to the listener API.

Steps (from host):

1. Exec into the tester container:
   ```bash
   docker exec -it python-tester bash
   ```
2. Run a quick HTTP server on a chosen port (e.g., 7002):
   ```bash
   python - <<'PY'
import http.server, socketserver
PORT=7002
httpd=socketserver.TCPServer(('', PORT), http.server.SimpleHTTPRequestHandler)
print('listening', PORT)
httpd.serve_forever()
PY
   ```
3. In another host terminal, kill it to generate a close event:
   ```bash
   docker exec python-tester bash -lc "pid=$(lsof -t -i :7002 || true); [ -n \"$pid\" ] && kill $pid || true"
   ```

The tester image already runs the watcher (fallback) and posts events to `http://listner-api:8080/ingest`.
