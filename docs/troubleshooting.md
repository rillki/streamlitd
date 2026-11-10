# Troubleshooting & FAQ

### `dub build` fails with errors inside vibe.d, or about named arguments
dub picked the wrong compiler (often `gdc`). Use `dub build --compiler=ldc2` (or `--compiler=dmd`),
or `export DC=ldc2`. LDC ≥ 1.36 or DMD ≥ 2.106 is required; gdc is not supported.

### "named arguments with Implicit Function Template Instantiation are not supported yet"
You passed a named argument to a template function, e.g. `st.radioOf("x", [1, 2], horizontal: true)`.
Give the type explicitly: `st.radioOf!int(...)`, or use the `string[]` version (`st.radio`).

### The page stays on "Running…"
Your code is in a long loop without any `st.*` call. In threaded mode (the default) other users
are not affected. Add `st.sleep(0)` (or any `st.*` call) inside long loops so the run can be
interrupted, or move the work into `cacheData`.

### "with symbol `St.xxx` is shadowing local symbol"
Inside `with (container) { ... }`, `St` method names such as `status`, `text`, `map`, `table`
and `image` win over your own variables and functions. Rename the variable, or don't use `with`
for that block.

### `st.fragment(...)` / `st.dialog(...)` with a named function
They take a delegate. Pass a lambda, `(St f) { ... }`, or wrap the function:
`import std.functional : toDelegate; st.fragment(toDelegate(&myFragment));`.

### `DuplicateWidgetID` error
Two widgets of the same type and label were created in one run. Give them distinct `key:` values.

### A widget resets to its default
Its label or options changed (a new widget identity), or it was not drawn in a run (for example it
was inside an `if`). Use a `key:` to keep the identity stable, and store long-lived values in
`st.session`.

### My callback's changes appear one run late
Callbacks run **before** the next run, so reading `st.session` after the widget call already sees
the change. If you change state *after* a widget was drawn (e.g. `if (st.button("Reset")) st.session["x"] = 0;`
below the widget bound to `"x"`), call `st.rerun()` to redraw.

### WebSocket fails with 403 behind a proxy
The browser's `Origin` does not match the `Host` the app sees. Forward the `Host` header
(`proxy_set_header Host $host;`), or set `[server] allowedOrigins = ["https://your.public.host"]`.

### The app works on `/` but not under `/myapp/` behind nginx
Start it with `--base-url-path /myapp`, and make sure `proxy_pass` has no trailing slash, so the
prefix is forwarded. See [Deployment](deployment.md#4-reverse-proxy).

### Maps are grey
The browser cannot reach the tile server (OpenStreetMap by default). Configure an internal tile
server: `[map] tileUrl = "https://tiles.internal/{z}/{x}/{y}.png"`.

### Uploads fail for large files
Raise `--max-upload-mb` (default 200), and the proxy's limit (`client_max_body_size` in nginx).

### I added a file to `assets/` (library development) and it returns 404
Assets are embedded at compile time, from the list in `source/streamlitd/assetlist.d`.
Regenerate it with `python3 tools/gen_assets.py` and rebuild.

### Can I use `Thread.sleep`, threads, or global variables in my app?
Use `st.sleep` instead of `Thread.sleep`. Scripts run on worker threads, so protect `__gshared`
state with a mutex, or use `cacheData`/`cacheResource`, which are thread-safe. `--script-threads 0`
runs everything on one thread.

### How do I connect to a database?
Create the connection or pool once with `cacheResource`, and query inside `app`. vibe.d drivers
(`vibe-d-postgresql`, `vibe-mongodriver`) work in scripts, because worker threads have an event
loop. Convert the results with `DataFrame.fromStructs` or `DataFrame.fromJson`.

### Where do errors go?
Errors in app code are shown in the page, with the stack trace. Server errors (bad config, failed
startup) are printed to stderr.

### Does it work offline / air-gapped?
Yes. All JavaScript, CSS and fonts are inside the binary. Only `st.map` tiles (configurable),
external image URLs and OIDC providers need network access.
