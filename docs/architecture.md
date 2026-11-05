# Architecture (for contributors)

## Overview

```
 browser (assets/app.js)  ──WebSocket JSON──►  vibe.d server (server.d)
   renders element tree   ◄──── deltas ─────   AppSession per tab (session.d)
                                                 └─ runs app(St) on a worker thread (executor.d)
                                                      └─ St methods emit elements (delta.d + mixins)
```

## Source modules (`source/streamlitd/`)

| Module | Role |
|---|---|
| `package.d` | public imports, `StreamlitMain` mixin |
| `server.d` | HTTP routes, WebSocket handling, static assets, uploads, media, origin checks, CLI (`runMain`) |
| `config.d`, `toml.d`, `secrets.d` | configuration files, the TOML parser, `st.secrets` |
| `session.d` | `AppSession`: widget values, session state, pending events, full and fragment runs, interruption |
| `executor.d` | runs sessions on vibe.d worker threads; the thread-safe outbox transport |
| `delta.d` | `St` (DeltaGenerator): element paths, containers, the generic `widget()` helper, control flow, page config, themes, auth API |
| `elements.d`, `widgets.d`, `layout.d`, `dataelements.d`, `charts.d`, `mediaelements.d`, `pages.d`, `fragments.d`, `components.d` | mixin templates with the `St` methods for each area |
| `dataframe.d` | `DataFrame` |
| `cache.d` | `cacheData` / `cacheResource` |
| `media.d` | in-memory media (images, downloads) and uploads |
| `theme.d` | design-style presets, `Theme`, `ThemeTokens` |
| `auth.d`, `authserver.d` | PBKDF2, signed cookies; login routes and OIDC |
| `testing.d` | `AppTest` |
| `assetlist.d` | generated list of embedded assets (`tools/gen_assets.py`) |

## Protocol

All messages are JSON over one WebSocket per tab (`<base>/_stcore/ws`).

**Browser → server**

| Message | Fields |
|---|---|
| `rerun` | `updates` (widget id → value), `trigger` + `triggerValue` (buttons, chat input), `fragment` (rerun only this fragment), `page` (URL path), `query` (query params) |

**Server → browser**

| Message | Meaning |
|---|---|
| `new_session` | `sessionId`, theme presets, default theme |
| `script_started` / `script_finished` | run boundaries: `run` id, `status` (`ok`, `error`, `stopped`, `rerun`), `fragment` + `path` for fragment runs |
| `delta` | `path` (e.g. `[0, 3, 1]`) + `el` (element JSON with `kind`, and `block` for containers) |
| `page_config`, `set_theme`, `navigation`, `set_page`, `query_params`, `toast`, `effect`, `logo`, `navigate` | page-level effects |

Paths start with a root: `0` main area, `1` sidebar, `2` bottom (chat input), `3` dialogs.

## Rendering model (frontend)

`assets/app.js` keeps a tree of nodes keyed by path.

- **Run start:** every node of the run's scope (all roots, or the fragment's subtree) is marked
  not fresh. After 400 ms, the not-fresh ones are drawn faded ("stale").
- **Each delta:** the node at the path is created or updated. Widgets with the same id and kind
  are updated in place, so focus and caret survive. A changed element is re-rendered.
- **Run end** (status other than `rerun`): nodes that were not refreshed are removed.

Element renderers live in `RENDERERS`, container renderers in `BLOCKS`. Heavy libraries
(Vega, Plotly, KaTeX, highlight.js, Leaflet) load lazily from `static/vendor/` the first time
they are needed.

## Widget values

`St.widget!T` (in `delta.d`) is the single code path for all widgets. It:

- computes or validates the widget id and detects duplicates;
- resolves the value: from session state if the user set the key, otherwise the browser value,
  otherwise the default;
- registers the metadata used for callbacks and key binding;
- emits the element with its current value.

The browser sends **raw values** (indices for selection widgets). Decoding and validation happen
on the server, so a tampered value falls back to the default.

## Adding an element: checklist

1. Add a method to the matching mixin (e.g. `elements.d`) that calls `emit(jo("kind", "my_el", ...))`,
   or `widget!T(...)` for inputs.
2. Add a renderer `my_el(node, el)` to `RENDERERS` in `assets/app.js`. Set `node.update` if it can
   update in place.
3. Add styles to `assets/style.css`, using the theme tokens (`var(--primary)`, ...).
4. Add an `AppTest` unit test (`tests/unit/apptests.d`) and a Playwright check (`tests/e2e/specs/`).
5. Regenerate the docs: `python3 tools/gen_api_docs.py`.

## Vendored libraries

marked, Vega/Vega-Lite/Vega-Embed, Plotly.js, KaTeX, Leaflet and highlight.js live in
`assets/vendor/`. Their licenses are listed in
[`assets/vendor/licenses/README.md`](../assets/vendor/licenses/README.md). After adding or
updating files there, run `python3 tools/gen_assets.py`.

## Repository tools

| Tool | Purpose |
|---|---|
| `run-tests.sh` | unit tests, e2e tests and doc snippet compilation |
| `tools/gen_assets.py` | regenerate the embedded asset list |
| `tools/gen_api_docs.py` | regenerate `docs/api-reference.md` |
| `tools/check_doc_snippets.py` | compile every D snippet in `docs/` and check links |
| `tests/e2e/screenshots.js` + `tools/optimize_images.py` | regenerate `docs/images/` |
