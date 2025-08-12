# Node.js tester

Run a simple TCP/HTTP server inside the container to generate open/close events that the watcher forwards to the listener API.

Steps (from host):

1. Exec into the tester container:
   ```bash
   docker exec -it nodejs-tester bash
   ```
2. Run a quick HTTP server on a chosen port (e.g., 7001):
   ```bash
   node -e "require('http').createServer((req,res)=>res.end('ok')).listen(7001)"
   ```
3. In another host terminal, you can kill it to generate a close event:
   ```bash
   docker exec nodejs-tester bash -lc "pid=$(lsof -t -i :7001 || true); [ -n \"$pid\" ] && kill $pid || true"
   ```

The tester image already runs the watcher (fallback) and posts events to `http://listner-api:8080/ingest`.
