# Configuration

Settings come from four sources. Later sources override earlier ones:

1. **Defaults**
2. **Config files** (merged in this order):
   - `~/.streamlitd/config.toml` (per user)
   - `.streamlit/config.toml` (an existing Streamlit config, read for easier migration)
   - `.streamlitd/config.toml` (the project config)
3. **Environment variables** `STREAMLITD_SERVER_*`, `STREAMLITD_THEME_*`
4. **Command-line flags**

Paths are relative to the **working directory** the app is started from. Use
`--config path/to/file.toml` to read a single specific file instead.

## `config.toml`

```toml
[server]
port = 8501                  # --port
address = "0.0.0.0"          # --host (bind address)
baseUrlPath = ""             # --base-url-path, e.g. "/reports" behind a reverse proxy
maxUploadSize = 200          # --max-upload-mb (MB)
scriptThreads = -1           # --script-threads: -1 = one per CPU core, 0 = single-threaded fibers
maxSessions = 0              # --max-sessions (0 = unlimited); extra connections get HTTP 503
idleTimeout = 0              # --idle-timeout (seconds without client activity; 0 = never; see below)
headless = false             # true = no startup banner (--quiet)
favicon = ""                 # --favicon: app-wide favicon image (svg, png, ico, jpg, gif, webp); default: the streamlitd icon
allowedOrigins = []          # --allowed-origin: extra Origins allowed to open the WebSocket / upload ("*" = any)

[theme]
design = "streamlit"         # --design: streamlit, terminal, retro, win95, xp, brutalist, material, glass
scheme = "streamlit"         # --color-scheme (alias --theme): streamlit, minimal, ocean, forest, sunset, finance, solarized, paper
                             #   (`preset` is accepted as an old name for `scheme`)
mode = "auto"                # --theme-mode: auto | light | dark   (Streamlit's `base` is accepted too)
allowSwitch = true           # false = hide the viewer style menu (--no-theme-switch)
# any theme token, see theming.md: primaryColor, backgroundColor, font, baseRadius, chartColors, ...

[theme.schemes.acme]         # your own color scheme (see extending.md); also [theme.schemes.acme.light] / .dark
label = "Acme Corp"
base = "streamlit"           # tokens not given come from this scheme
primaryColor = "#0055aa"     # any theme token, for both modes

[theme.designs.neon]         # your own design style (see extending.md)
label = "Neon"
css = "styles/neon.css"      # rules scoped by :root[data-design="neon"]
baseRadius = "6px"           # also font, headingFont, codeFont, strokeWidth, barRadius, gridDash

[elements.rating]            # browser files of a native custom widget (st.customWidget!T("rating", ...))
js = "ui/rating.js"
css = "ui/rating.css"

[map]
tileUrl = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
attribution = "&copy; OpenStreetMap contributors"

[auth]                       # usually kept in secrets.toml, see authentication.md
required = false             # --auth-required

[api]                        # OpenAPI + Swagger UI for the app's API, see api-endpoints.md
docs = false                 # --api-docs: serve them (off by default)
docsPath = "/docs"           # Swagger UI, under the base path (plain path, not under /_stcore, /static, /auth, ...)
specPath = "/openapi.json"   # the OpenAPI 3.0 document, under the base path (must differ from docsPath)
title = "streamlitd API"     # info.title
version = "1.0.0"            # info.version
```

`idleTimeout` frees the memory of abandoned tabs. If the tab is still open, the browser then
reconnects automatically, but with a **fresh session**: widget values and `st.session` are lost.
Set it well above your users' normal pauses, or leave it at 0.

Color schemes, designs and elements defined in several config files are merged by name: a later
file replaces the whole definition. They are registered when the server starts; an invalid color
or a missing file stops the app with an error.

Unknown keys and sections (for example Streamlit's `runOnSave` or `[browser]`) are ignored, with a
warning at startup. An existing `.streamlit/config.toml` can stay as it is.

## Environment variables

| Variable | Same as |
|---|---|
| `STREAMLITD_PORT`, `STREAMLITD_SERVER_PORT` | `[server] port` |
| `STREAMLITD_SERVER_ADDRESS` | `[server] address` |
| `STREAMLITD_SERVER_BASEURLPATH` | `[server] baseUrlPath` |
| `STREAMLITD_SERVER_MAXUPLOADSIZE` | `[server] maxUploadSize` |
| `STREAMLITD_SERVER_SCRIPTTHREADS` | `[server] scriptThreads` |
| `STREAMLITD_SERVER_MAXSESSIONS` | `[server] maxSessions` |
| `STREAMLITD_SERVER_IDLETIMEOUT` | `[server] idleTimeout` |
| `STREAMLITD_SERVER_HEADLESS` | `[server] headless` |
| `STREAMLITD_SERVER_FAVICON` | `[server] favicon` |
| `STREAMLITD_API_DOCS` (`true`/`false`, `1`/`0`, `yes`/`no`, `on`/`off`) | `[api] docs` |
| `STREAMLITD_API_DOCSPATH`, `_SPECPATH`, `_TITLE`, `_VERSION` | `[api] docsPath`, `specPath`, `title`, `version` |
| `STREAMLITD_THEME_DESIGN`, `_SCHEME` (or `_PRESET`), `_MODE`, `_BASE` | `[theme] design`, `scheme`, `mode`, `base` |
| `STREAMLITD_THEME_PRIMARYCOLOR`, `_BACKGROUNDCOLOR`, `_SECONDARYBACKGROUNDCOLOR`, `_TEXTCOLOR`, `_FONT`, `_HEADINGFONT`, `_CODEFONT`, `_BASERADIUS` | the theme tokens |

## Command-line flags

```
./app --help
```

| Flag | Default | Meaning |
|---|---|---|
| `--config <file>` | | read only this config file |
| `--port`, `-p` | 8501 | HTTP port |
| `--host` | `0.0.0.0` | bind address |
| `--base-url-path` | | serve under a path prefix |
| `--allowed-origin <origin>` | | extra allowed Origin (repeatable, `*` = any) |
| `--max-sessions` | 0 | maximum concurrent sessions |
| `--idle-timeout` | 0 | close idle sessions after N seconds |
| `--max-upload-mb` | 200 | upload size limit |
| `--script-threads` | -1 | worker threads for app scripts |
| `--design` | `streamlit` | design style |
| `--color-scheme` (alias `--theme`), `--theme-mode` | `streamlit`, `auto` | color scheme and mode |
| `--theme.<key>=<value>` | | any theme token, e.g. `--theme.primaryColor=#123456` |
| `--no-theme-switch` | | hide the viewer style menu |
| `--auth-required` | | require login for the whole app |
| `--favicon <file>` | streamlitd icon | favicon image for every page (svg, png, ico, …) |
| `--api-docs`, `--api-docs=false` | off | serve the OpenAPI document and Swagger UI ([API endpoints](api-endpoints.md#openapi-and-swagger-ui)) |
| `--hash-password` | | read a password from stdin, print its hash for `secrets.toml`, exit |
| `--quiet`, `-q` | | no startup banner |

## Build-time switches (dub versions)

Set in the app's `dub.json` (they also apply to the streamlitd library it depends on):

| Version | Effect |
|---|---|
| `StreamlitdNoApiDocs` | leaves the OpenAPI generator and Swagger UI out of the binary (about 1.7 MB); `[api] docs` then only prints a warning |

```json
"versions": ["StreamlitdNoApiDocs"]
```

## Secrets: `secrets.toml`

Secrets are read from these files (later ones override; tables are merged):

1. `~/.streamlitd/secrets.toml`
2. `.streamlit/secrets.toml`
3. `.streamlitd/secrets.toml`

```toml
api_key = "sk-..."

[db]
host = "db.internal"
user = "report_reader"
password = "..."
```

<!-- wrap -->
```d
auto user = st.secrets["db"]["user"].get!string;          // throws if missing
auto pass = st.secrets.get!string("db.password");         // dotted path
auto port = st.secrets.get!int("db.port", 5432);          // with a default
if ("api_key" in st.secrets)
    st.write("API key configured");
```

`secrets()` gives the same object outside of `app`, for example in a `cacheResource` function
that opens a database pool. Secrets are **never sent to the browser**. Add `secrets.toml` to
`.gitignore`, and mount it at runtime in containers (see [Deployment](deployment.md)).

## Programmatic configuration

Instead of `mixin StreamlitMain!app`, you can build the options yourself:

<!-- compile -->
```d
import streamlitd;
import std.functional : toDelegate;

void app(St st) { st.write("hi"); }

int main()
{
    ServerOptions o;
    o.port = 9000;
    o.theme.scheme = "ocean";
    o.theme.design = "material";
    o.scriptThreads = 4;
    return serve(toDelegate(&app), o);
}
```

Pass your own routes as the third argument, `serve(toDelegate(&app), o, toDelegate(&routes))`
(see [JSON API endpoints](api-endpoints.md)).

`runMain(toDelegate(&app), args)` is what the mixin calls: config files, environment, CLI, then
`serve`.
