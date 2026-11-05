# streamlitd

Write reactive data apps in **D** the way you write them in Python with
[Streamlit](https://streamlit.io): a plain function that runs from top to bottom
on every interaction. streamlitd builds to **one self-contained executable**.
The web UI, Vega-Lite charts and Markdown renderer are compiled into the
binary, so it works offline.

```d
import streamlitd;

void app(St st)
{
    st.title("Hello 👋");
    auto name = st.textInput("Your name", "World");
    auto n = st.slider("Times", 1, 10, 3);
    if (st.button("Greet", type: "primary"))
        st.success("Hello " ~ name ~ "!");
}

mixin StreamlitMain!app;   // generates main(): ./app --port 8501
```

```
cd examples/hello && dub run --compiler=ldc2 -- --port 8501
```

## How it works

* **Server.** vibe.d serves the page, the embedded assets and a WebSocket at `/_stcore/ws`.
  * Each browser tab gets an `AppSession` (fiber).
  * A widget change sends `{type:"rerun", updates:{id:value}}`.
  * The server then reruns `app(st)` and streams `delta` messages (path + element JSON).
* **Rerun semantics follow Streamlit.**
  * Widgets return their current value.
  * Buttons are `true` for exactly one run.
  * Callbacks (`onChange` / `onClick`) run before the script.
  * Widget values with a `key` live in `st.session[key]`.
  * Elements that were not re-emitted are removed when the run finishes.
  * A new event arriving mid-run interrupts the run at the next `st.*` call.
* **Frontend.** `assets/app.js` is vanilla JS (no build step).

## Python → D cheat sheet

D 2.106 (LDC 1.36) supports named arguments for non-template functions, so most calls look like Python.

| Python | D |
|---|---|
| `st.title("x")`, `st.header`, `st.subheader`, `st.markdown`, `st.caption`, `st.text`, `st.code`, `st.divider`, `st.html` | same names: `st.title("x")` … |
| `st.write(a, b)` | `st.write(a, b)` (strings → markdown, DataFrame → table, structs/arrays/Json → JSON) |
| `st.success/info/warning/error`, `st.exception(e)` | same |
| `st.metric("A", 42, "+3")` | `st.metric("A", 42, "+3")` |
| `st.json(obj)` | `st.json(obj)` (Json, string, struct, AA, …) |
| `st.button("Go", on_click=f)` | `st.button("Go", onClick: () { ... })` |
| `st.checkbox`, `st.toggle` | `st.checkbox("x")`, `st.toggle("x")` |
| `st.radio("x", opts, horizontal=True)` | `st.radio("x", opts, horizontal: true)`; other types: `st.radioOf!T(...)` |
| `st.selectbox("x", opts, index=None)` | `st.selectbox("x", opts, index: -1)`; any type: `st.selectboxOf!T(..., formatFunc: ...)` |
| `st.multiselect("x", opts, default=[...])` | `st.multiselect("x", opts, ["a"])` / `multiselectOf!T` |
| `st.slider("x", 0, 100, 25)` / `(20, 80)` | `st.slider("x", 0, 100, 25)` / `st.slider("x", 0.0, 1.0, [0.2, 0.8])` |
| `st.select_slider` | `st.selectSlider` / `selectSliderOf!T` |
| `st.number_input("x", value=5)` | `st.numberInput("x", 5)` (int) / `st.numberInput("x", 1.5)` (double) |
| `st.text_input(type="password")`, `st.text_area` | `st.textInput("x", type: "password")`, `st.textArea` |
| `st.date_input`, `st.time_input`, `st.color_picker` | `st.dateInput` (`Date`), `st.timeInput` (`TimeOfDay`), `st.colorPicker` |
| `st.file_uploader(type=["csv"])` | `st.fileUploader("x", ["csv"])` → `UploadedFile` or `null`; `fileUploaderMulti` |
| `st.download_button("x", data, "f.csv")` | `st.downloadButton("x", data, "f.csv", "text/csv")` |
| `st.image`, `st.audio`, `st.video` | same (bytes, file path or http(s)/data URL) |
| `st.sidebar.x(...)` / `with st.sidebar:` | `st.sidebar.x(...)` / `with (st.sidebar) { x(...); }` |
| `c1, c2 = st.columns(2)` / `st.columns([2,1])` | `auto c = st.columns(2); c[0].write(...)` / `st.columns([2.0, 1])` |
| `st.tabs([...])`, `st.expander`, `st.container(border=True)`, `st.empty()`, `st.popover` | same; `with (st.expander("x")) { ... }` |
| `with st.form("f"): ...; st.form_submit_button()` | `auto f = st.form("f"); f.textInput(...); if (f.formSubmitButton("Send")) ...` |
| `st.session_state.x` / `["x"]` | `st.session["x"] = v; st.session.get!int("x"); st.session.setDefault("x", 0)` |
| `st.rerun()`, `st.stop()` | same |
| `st.toast`, `st.spinner`, `st.progress`, `st.balloons` | same; `{ auto s = st.spinner("..."); work(); }`; `auto bar = st.progress(0); bar.progress(50);` |
| `time.sleep(1)` | `st.sleep(1)` (does not block other sessions) |
| `pd.DataFrame` | `DataFrame.fromStructs(rows)`, `DataFrame.fromCsv(text)`, `readCsv(path)`, `fromJson(records)`, `new DataFrame().addColumn("a", [1,2])` with `filter`, `sortBy`, `groupBy`, `head`, `select`, `sum`/`mean`, `toCsv` |
| `pd.DataFrame(records)` | `DataFrame.fromJson(records, ["col1", "col2"])` — JSON objects don't keep key order, so pass the order (else columns are sorted) |
| `st.dataframe(df)`, `st.table(df)` | same (sortable, searchable, CSV export) |
| `st.data_editor(df, num_rows="dynamic")` | `st.dataEditor(df, numRows: "dynamic")` → edited `DataFrame` |
| `st.line_chart(df, x=, y=[...])`, `bar_chart`, `area_chart`, `scatter_chart` | `st.lineChart(df, x: "day", y: ["a", "b"])` … |
| `st.vega_lite_chart(df, spec)` | `st.vegaLiteChart(spec, df)` |
| `@st.cache_data(ttl=60)` | `cacheData!(fn, 60)(args)` (returns a `.dup` copy, like Streamlit); `cacheResource!fn(args)` (shared object); `cacheClear!fn()` |
| `st.navigation([st.Page(f, title=...)])` | `st.navigation([Page(&f, "Title", "📈")]).run(st)`; `st.switchPage`, `st.pageLink` |
| `st.chat_message("user")`, `st.chat_input()` | `st.chatMessage("user").markdown(...)`; `if (auto p = st.chatInput("Say")) ...` |
| `st.set_page_config(layout="wide")` | `st.setPageConfig(title: "x", icon: "📊", layout: Layout.wide, theme: "ocean")` |
| `config.toml [theme]` / `--theme.primaryColor` | `st.setTheme(...)` / `--theme ocean --theme.primaryColor=#..` (see Design styles) |
| `st.query_params["x"]` | `st.queryParams["x"]`, `st.queryParams["x"] = "1"` |
| `@st.fragment(run_every=5)` | `st.fragment((St f) { ... }, runEvery: 5)`; `st.rerun(scope_: "fragment")` |
| `@st.dialog("Title")` | `st.dialog("Title", (St d) { ... }, width: "large")` |
| `with st.status("..."): ...` | `auto s = st.status("..."); s.write(...); s.update(label: "Done", state: "complete")` |
| `st.pills` / `st.segmented_control` / `st.feedback` | `st.pills`, `st.pillsMulti`, `st.segmentedControl(Multi)`, `st.feedback("stars")` |
| `st.link_button`, `st.badge`, `st.logo` | `st.linkButton(label, url)`, `st.badge("New", color: "green")`, `st.logo("logo.png")` |
| `st.latex(r"...")`, `$math$` in markdown | `st.latex(...)` (KaTeX bundled); `$...$` / `$$...$$` in markdown |
| `st.code(src, language="python")` | same, with highlight.js syntax highlighting |
| `st.plotly_chart(fig, on_select="rerun")` | `st.plotlyChart(figJson, onSelect: "rerun")` → selection `Json` |
| `st.map(df)` | `st.map(df, size: "radius_m", color: "#ff0000")` (Leaflet) |
| `components.html(...)` / `components.iframe(...)` | `st.components.html(...)` / `st.iframe(url)` |
| `components.declare_component("x", path=...)` | `auto c = declareComponent("x", path: "frontend/build"); auto v = c(st, args, key: "k");` |
| `st.secrets["db"]["user"]` | `st.secrets["db"]["user"].get!string`, `st.secrets.get!string("db.user")` |
| `st.user`, `st.login()`, `st.logout()` | `st.user.isLoggedIn/name/email`, `st.login("google")`, `st.logout()` |
| `streamlit.testing.v1.AppTest` | `new AppTest(&app).run()`, `.setValue(kind, label, Json)`, `.click(label)`, `.texts(kind)` |

**Note on named arguments.** LDC 1.36 does not support named arguments together with template
argument deduction. Call generic widgets with an explicit type, e.g.
`st.radioOf!int("Size", [1, 2, 3], horizontal: true)`.

## Design styles (themes)

Streamlit itself offers only Light/Dark ("Use system setting") plus custom `[theme]` keys
in `.streamlit/config.toml`. streamlitd keeps that model and adds **named presets**.
Each preset has both a light and a dark variant:

| preset | look |
|---|---|
| `streamlit` | default Streamlit look |
| `minimal` | monochrome, outlined inputs |
| `ocean` | cool blues, rounder corners |
| `forest` | greens on warm off-white |
| `sunset` | orange/violet, rounded font |
| `finance` | navy + green dashboard look |
| `solarized` | Solarized palettes, mono headings |
| `paper` | editorial serif |

```d
st.setTheme("ocean");                      // preset, mode stays "auto" (follows the OS)
st.setTheme("finance", "dark");            // preset + mode: "auto" | "light" | "dark"
st.setPageConfig(title: "Report", theme: "paper", allowThemeSwitch: false);

auto t = Theme("minimal", "light");        // preset + Streamlit-style overrides
t.overrides.primaryColor = "#7c3aed";
t.overrides.font = fontSerif;
st.setTheme(t);
```

* **Server-wide default.** Pass it on the command line, the same way Streamlit's `--theme.*` flags work:
  `./app --theme ocean --theme-mode dark --theme.primaryColor=#0055aa`.
* **Override keys** (all optional):
  `primaryColor`, `primaryTextColor`, `backgroundColor`, `secondaryBackgroundColor`, `textColor`,
  `linkColor`, `borderColor`, `sidebarBackgroundColor`, `widgetBackgroundColor`, `widgetBorderColor`,
  `codeBackgroundColor`, `font`, `headingFont`, `codeFont`, `baseRadius`, `chartColors`.
* **Viewer choice.** The ⚙ menu (top right) lets viewers pick a style and System/Light/Dark mode.
  * The choice is remembered in the browser.
  * It is dropped as soon as the app explicitly switches to a different theme.
  * `allowThemeSwitch: false` (or `--no-theme-switch`) hides the menu.
* **Charts.** Chart palettes, fonts and grid colors follow the active style.
* **Example.** Run `examples/themes` to try every preset.

## Production setup

**Configuration.** Settings come from these sources; later ones win:
1. `~/.streamlitd/config.toml`
2. `.streamlit/config.toml`
3. `.streamlitd/config.toml`
4. `STREAMLITD_SERVER_*` / `STREAMLITD_THEME_*` environment variables
5. command-line flags (`./app --help` lists them)

```toml
# .streamlitd/config.toml
[server]
port = 8501
address = "0.0.0.0"
baseUrlPath = "/reports"        # serve behind a reverse proxy under a prefix
scriptThreads = -1              # worker threads for scripts (-1 = CPU cores, 0 = single-threaded)
maxSessions = 500
idleTimeout = 0                 # seconds, 0 = never
maxUploadSize = 200             # MB
allowedOrigins = ["https://portal.example.com"]   # extra origins allowed to connect
[theme]
preset = "finance"
[map]
tileUrl = "https://tiles.internal/{z}/{x}/{y}.png" # offline/internal map tiles
```

* **Worker threads.** Each run executes on a vibe.d worker thread, so a CPU-heavy session does not freeze the other sessions. A worker thread has its own event loop, so vibe.d database drivers and `st.sleep` work inside scripts.
* **Secrets.** `st.secrets` reads `.streamlitd/secrets.toml` (or `.streamlit/secrets.toml`). Secrets never reach the browser.
* **Origin check.** WebSocket and upload requests from a foreign `Origin` are rejected with 403.
* **Docker.**
  ```
  docker build --build-arg APP=examples/prod -t my-app .
  docker run -p 8501:8501 my-app
  ```
* **nginx** (with `baseUrlPath = "/reports"`):
  ```nginx
  location /reports/ {
      proxy_pass http://127.0.0.1:8501;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_read_timeout 86400;
  }
  ```

## Authentication

Configure auth in `secrets.toml`, as in Streamlit 1.42+. With `required = true` the whole app sits behind a login page. Otherwise, check `st.user.isLoggedIn` and call `st.login()` yourself.

```toml
[auth]
required = true
cookie_secret = "a-long-random-string"
redirect_uri = "https://example.com/reports/oauth2callback"

[auth.google]                      # any OIDC provider (Google, Microsoft Entra ID, Keycloak, Okta, ...)
label = "Google"
client_id = "..."
client_secret = "..."
server_metadata_url = "https://accounts.google.com/.well-known/openid-configuration"

[auth.users.alice]                 # built-in password users
password_hash = "pbkdf2_sha256$200000$..."   # echo 'password' | ./app --hash-password
name = "Alice"
email = "alice@example.com"
```

* The login cookie is HMAC-signed, HttpOnly and SameSite=Lax.
* Password hashes use PBKDF2-HMAC-SHA256 and are verified off the event loop.
* Inside the app: `st.user.isLoggedIn`, `st.user.name`, `st.user.email`, `st.login()` and `st.logout()`.

## Custom components

`declareComponent` speaks Streamlit's component postMessage protocol, so frontends built with `streamlit-component-lib` work as long as their arguments and values are JSON. Arrow DataFrame arguments are not supported.

Like in Streamlit, component iframes use `allow-scripts allow-same-origin`. Only use components you trust. See `examples/extras/counter/index.html` for a dependency-free example.

## Project layout

```
source/streamlitd/   library: server, session, St (delta generator), widgets, layout,
                     dataframe, charts, media, pages, cache, testing (AppTest)
assets/              index.html, app.js, style.css, vendor/ (marked, vega, vega-lite, vega-embed)
examples/            hello, widgets, data, multipage, themes, prod, fragments, extras, auth
tests/unit/          headless AppTest suites (run by `dub test`)
tests/e2e/           Playwright tests that build and start each example
```

## Tests

```
./run-tests.sh            # dub test + Playwright
dub test --compiler=ldc2  # unit tests only
cd tests/e2e && npx playwright test
```

Playwright uses the Chromium in `~/.cache/ms-playwright` (or `CHROMIUM_PATH`).

## Not implemented yet

* `st.connection` (SQL helpers)
* `column_config`
* dataframe/chart selection events, except on Plotly
* `st.pydeck_chart`
* `st.pyplot`
* `st.camera_input` / `st.audio_input`
* Arrow data in custom components
* hot reload (`streamlitd run`)

Scripts run in fibers on vibe.d worker threads. Use `st.sleep` rather than `Thread.sleep` inside scripts.
