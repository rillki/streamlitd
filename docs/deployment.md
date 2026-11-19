# Deployment

A streamlitd app is **one executable**. The web UI, chart libraries, fonts and icons are
compiled into it. Deploying means copying that binary (plus your data files and
`.streamlitd/config.toml`) to a server and running it behind a reverse proxy.

## 1. Release build

```sh
dub build --compiler=ldc2 --build=release
```

By default the binary links the D runtime dynamically (`libphobos2-ldc-shared`). To get a
binary that only needs libc, OpenSSL and zlib, link Phobos statically. Add this to your
`dub.json`:

```json
"dflags-ldc": ["-link-defaultlib-shared=false"]
```

```
$ ldd ./myapp
    libssl.so.3  libcrypto.so.3  libz.so.1  libm.so.6  libgcc_s.so.1  libc.so.6
```

A release build of the `hello` example is about 12 MB. Copy the binary to any Linux machine with
the same (or newer) glibc and OpenSSL 3.

## 2. Run it as a service (systemd)

`/etc/systemd/system/sales-dashboard.service`:

```ini
[Unit]
Description=Sales dashboard (streamlitd)
After=network-online.target

[Service]
User=streamlitd
# the working directory contains .streamlitd/ and data/
WorkingDirectory=/opt/sales-dashboard
ExecStart=/opt/sales-dashboard/myapp --host 127.0.0.1 --port 8501 --quiet
Restart=on-failure
Environment=STREAMLITD_THEME_PRESET=finance
# secrets.toml readable only by this user: chmod 600 .streamlitd/secrets.toml
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/opt/sales-dashboard/data

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload && sudo systemctl enable --now sales-dashboard
journalctl -u sales-dashboard -f        # logs (errors go to stderr)
```

## 3. Docker

The repository has a multi-stage [`Dockerfile`](../Dockerfile):

- The **build stage** (Ubuntu 24.04 with `ldc`, `dub`, `libssl-dev`) builds the dub project
  given by the `APP` build argument, in release mode.
- The **runtime stage** (Ubuntu 24.04 with `libphobos2-ldc-shared106`, `libssl3`, `zlib1g`) contains only the
  binary and `.streamlitd/config.toml`. It runs as a non-root user and listens on port 8501, with a
  TCP health check.
- **Secrets are never copied into the image.** `.dockerignore` excludes every `secrets.toml`.

```sh
docker build --build-arg APP=examples/prod -t sales-dashboard .
docker run -d --name sales -p 8501:8501 \
  -v $PWD/examples/prod/.streamlitd/secrets.toml:/app/.streamlitd/secrets.toml:ro \
  sales-dashboard
```

For your own project, copy the Dockerfile next to your `dub.json` and set `APP=.`. If your app
reads data files, add `COPY` lines for them (the working directory is `/app`). Settings can be
overridden with `-e STREAMLITD_SERVER_BASEURLPATH=/sales` or with arguments after the image
name:

```sh
docker run -p 8501:8501 sales-dashboard --color-scheme ocean --max-sessions 200
```

### docker-compose

```yaml
services:
  dashboard:
    build:
      context: .
      args: { APP: "." }
    restart: unless-stopped
    environment:
      STREAMLITD_SERVER_BASEURLPATH: /sales
      STREAMLITD_THEME_PRESET: finance
    volumes:
      - ./secrets.toml:/app/.streamlitd/secrets.toml:ro
      - ./data:/app/data:ro
    expose: ["8501"]

  nginx:
    image: nginx:1.27
    ports: ["80:80"]
    volumes: ["./nginx.conf:/etc/nginx/conf.d/default.conf:ro"]
    depends_on: [dashboard]
```

## 4. Reverse proxy

streamlitd speaks plain HTTP plus a WebSocket at `<base>/_stcore/ws`. Terminate TLS at the
proxy, and forward the `Upgrade`, `Host` and `X-Forwarded-Proto` headers.

### nginx (app under `/sales/`)

```nginx
location /sales/ {
    proxy_pass http://127.0.0.1:8501;        # no trailing slash: keep the /sales prefix
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 86400;                # keep idle WebSockets open
    client_max_body_size 200m;               # match --max-upload-mb
}
```

Start the app with `--base-url-path /sales` (or `[server] baseUrlPath = "/sales"`). All URLs
the frontend uses are relative to that base, including deep links to pages.

### Traefik (labels)

```yaml
labels:
  - traefik.http.routers.sales.rule=Host(`apps.example.com`) && PathPrefix(`/sales`)
  - traefik.http.services.sales.loadbalancer.server.port=8501
```

### Origin checks behind a proxy

WebSocket and upload requests are only accepted when the browser's `Origin` matches the `Host`
header the app sees. Either forward `Host` (as above), or allow the public origin explicitly:

```toml
[server]
allowedOrigins = ["https://apps.example.com"]
```

## 5. Health checks and monitoring

- `GET <base>/docs` and `<base>/openapi.json` serve Swagger UI and the OpenAPI document when
  `[api] docs = true` (see [API endpoints](api-endpoints.md#openapi-and-swagger-ui)).
- `GET <base>/favicon.ico` (and `/favicon.ico` at the server root) serves the app-wide favicon,
  or streamlitd's default icon. Configure it with `[server] favicon` / `--favicon`.
- `GET <base>/_stcore/health` returns `ok` with HTTP 200. Use it for load balancer and
  Kubernetes probes. It does not require login.
- Errors from app code are shown to the user and are not logged. Wrap sensitive sections with
  your own logging (`std.stdio.stderr.writeln`, `vibe.core.log.logError`), which goes to
  stdout/stderr (journald or `docker logs`).

## 6. Sizing and scaling

- **One process serves many users.** Each run executes on a worker thread
  (`--script-threads`, default one per CPU core), so CPU-heavy pages don't block each other.
  - The load test (`node tests/load/load.mjs --sessions 200`) runs 200 simultaneous sessions on
    4 script threads with a p95 run time of about 40 ms. It also checks that no session sees
    another's values.
  - Wrap blocking, non-vibe calls (ODBC, C drivers, `std.net.curl`) in `blocking(...)`, so they
    don't hold up the other sessions on the same thread
    ([Threads](concepts.md#threads-and-blocking)).
- **Memory:** each session keeps its widget values, `st.session` contents, uploaded files and
  the media it currently shows. Use `--max-sessions` and `--idle-timeout` to bound it. An idle tab
  that hits the timeout reconnects with a fresh session, so its state is lost.
- **Multiple replicas** behind a load balancer need **sticky sessions**: a browser tab must talk
  to the same process, because the WebSocket session, uploads and media URLs live in that process.
  Use cookie-based affinity (Traefik `sticky.cookie`, nginx `ip_hash` or `sticky`). Caches are
  per process.
- **Restarts** drop sessions. Browsers reconnect automatically (with a "Connecting…" banner) and
  start a fresh session. Keep anything important in a database, not in `st.session`.

## 7. Kubernetes (sketch)

```yaml
containers:
  - name: dashboard
    image: registry.example.com/sales-dashboard:1.0
    args: ["--base-url-path", "/sales"]
    ports: [{ containerPort: 8501 }]
    readinessProbe: { httpGet: { path: /sales/_stcore/health, port: 8501 } }
    livenessProbe:  { httpGet: { path: /sales/_stcore/health, port: 8501 } }
    volumeMounts:
      - { name: secrets, mountPath: /app/.streamlitd/secrets.toml, subPath: secrets.toml, readOnly: true }
volumes:
  - name: secrets
    secret: { secretName: sales-dashboard-secrets }
```

For more than one replica, enable session affinity, e.g. with the ingress annotation
`nginx.ingress.kubernetes.io/affinity: cookie`.

## 8. Security checklist

- [ ] Put the app behind a TLS-terminating proxy; keep it on `127.0.0.1` or a private network.
- [ ] Keep `secrets.toml` out of git and out of images; mount it read-only.
- [ ] Use `[auth]` (see [Authentication](authentication.md)) for anything non-public; set a
      long random `cookie_secret` (or keep the generated `.streamlitd/auth_secret`).
- [ ] With accounts: keep the user store (`.streamlitd/users.json`, or `users_file`) on a persistent,
      backed-up volume that only the app's user can read; one server process per file. Behind a
      proxy, set `[server] trustProxy = true` so login limits see the real client address.
- [ ] Set `allowedOrigins` only if you really embed the app on another site.
- [ ] Set `--max-upload-mb`, `--max-sessions` and `--idle-timeout` to fit your environment.
- [ ] Keep the API docs (`[api] docs`, off by default) off on public deployments unless you want the
      API's description to be visible, or build with the dub version `StreamlitdNoApiDocs` to leave
      them out of the binary ([API endpoints](api-endpoints.md#openapi-and-swagger-ui)).
- [ ] Only use custom components you trust (they run with access to the page).
