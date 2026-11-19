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
| `server.d` | HTTP routes, WebSocket handling, static assets, uploads, media, origin checks, CLI (`runMain`), app routes (`RoutesFn`, `apiUser`/`requireUser`) |
| `config.d`, `toml.d`, `secrets.d` | configuration files, the TOML parser, `st.secrets` |
| `session.d` | `AppSession`: widget values, session state, pending events, full and fragment runs, interruption |
| `executor.d` | runs sessions on vibe.d worker threads; the thread-safe outbox transport |
| `delta.d` | `St` (DeltaGenerator): element paths, containers, the generic `widget()` helper, control flow, page config, themes, auth API |
| `elements.d`, `widgets.d`, `layout.d`, `dataelements.d`, `charts.d`, `mediaelements.d`, `pages.d`, `fragments.d`, `components.d` | mixin templates with the `St` methods for each area |
| `dataframe.d` | `DataFrame` |
| `cache.d` | `cacheData` / `cacheResource` |
| `media.d` | in-memory media (images, downloads) and uploads |
| `theme.d` | design styles (`DesignStyle`), color schemes, `Theme`, `ThemeTokens` |
| `auth.d`, `authserver.d` | PBKDF2, signed cookies; the login, sign-up, account and reset pages, OIDC, CSRF tokens |
| `accounts.d` | accounts: `UserStore` (default `JsonFileUserStore`), registration modes, roles, invites, reset links, `LoginThrottle`; the `Accounts` service (`accounts()`) |
| `useradmin.d` | `St` methods for accounts: `st.accounts`, `requireLogin`, `requireRole`, `userAdmin()` |
| `testing.d` | `AppTest` |
| `assetlist.d` | generated list of embedded assets (`tools/gen_assets.py`); Swagger UI has its own list, `swaggerAssetNames` |
| `columnconfig.d` | `ColumnConfig` (column types, formats, colours) for `dataframe`, `table`, `dataEditor`; the table renderer is `assets/table.js` |
| `calendar.d` | `st.calendarGrid` (`GridRow`, `GridItem`, `GridEvent`); rendered by `assets/calendar.js` |
| `blocking.d` | `blocking(fn)`: a blocking call on its own thread while the vibe.d task yields |
| `liveregistry.d` | the open sessions, for `refreshFragments` |
| `extensions.d` | app-defined native elements and widgets (`registerElement`, `st.customElement`, `st.customWidget!T`) and the combined extension stylesheet/script; the scheme and design registries live in `theme.d` |
| `openapi.d` | `registerApi`, OpenAPI 3.0 generation from REST interfaces (compile-time schemas), Swagger UI page; compiled out with the version `StreamlitdNoApiDocs` |

## Protocol

All messages are JSON over one WebSocket per tab (`<base>/_stcore/ws`).

**Browser → server**

| Message | Fields |
|---|---|
| `rerun` | `updates` (widget id → value), `trigger` + `triggerValue` (buttons, chat input), `fragment` (rerun only this fragment), `page` (URL path), `query` (query params) |

**Server → browser**

| Message | Meaning |
|---|---|
| `new_session` | `sessionId`, color schemes (`themes`), design styles (`designs`), default theme, header controls (`ui`: `rerunButton`, `settingsButton`, `rerunShortcut`) |
| `script_started` / `script_finished` | run boundaries: `run` id, `status` (`ok`, `error`, `stopped`, `rerun`), `fragment` + `path` for fragment runs |
| `delta` | `path` (e.g. `[0, 3, 1]`) + `el` (element JSON with `kind`, and `block` for containers) |
| `page_config` (also `rerunButton`/`settingsButton` overrides), `set_theme`, `navigation`, `set_page`, `query_params`, `toast`, `effect`, `logo`, `navigate` | page-level effects (`navigate` to `auth/login` gets `?next=<current page>` in the browser, so the login returns there) |

Paths start with a root: `0` main area, `1` sidebar, `2` bottom (chat input), `3` dialogs, `4` header bar
(`st.topbar`, `userMenu`), `5` footer (`st.footer`), `6` banners (`st.banner`). Roots 1, 2, 4, 5 and 6 are
hidden while they have no visible content (`updateSidebarVisibility` in `app.js`).

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

## UI kit: themed controls instead of native browser pop-ups

streamlitd never uses the browser's own `<select>`, date, time or color pop-ups: they cannot be styled
and look different on every OS. `assets/ui.js` (`window.StUI`, loaded before `app.js`) provides:

| Component | Used by | Notes |
|---|---|---|
| `openPopup(anchor, content, opts)` | every pop-up | rendered into a body-level portal `#stPopups` (`position: fixed`), so it is never clipped by `overflow` in dataframes, expanders, dialogs, the sidebar or the settings panel; flips above the anchor when there is no room below, stays inside the viewport, follows scrolling, closes on outside click / Escape; nested pop-ups (the calendar's month/year lists) stack |
| `menu`, `attachMenu` | `menuButton`, `userMenu`, top-navigation sections and the phone ☰ menu | ARIA `menu`/`menuitem`; ↑/↓/Home/End, type-ahead, Enter/Space, Esc returns focus; the focused item gets `.active` so every design highlights it; separators and headings; link items open in a new tab with Ctrl/Cmd |
| `combobox` | `selectbox`, settings menu | searchable (type to filter, like Streamlit), ↑/↓/Home/End/PageUp/PageDown/Enter/Esc/Tab, ARIA `combobox` + `listbox` + `option`, placeholder |
| `multiCombobox` | `multiselect` | chips, list stays open while picking, Backspace removes the last chip, clear-all, `maxSelections` |
| `datePicker` | `date_input`, `dateRangeInput` (`range: true`) | typed `YYYY-MM-DD` (or `start – end`) or a calendar grid (min/max, today, keyboard: arrows/PageUp/PageDown/Home/End); in range mode two clicks pick the start and the end |
| `tagsInput` | `tagsInput` | free-text chips: Enter or comma adds, Backspace removes, optional suggestion list |
| `treeSelect` | `treeSelect` | ARIA `tree` in a pop-up with search; subtree checks with a partial state; committed when the pop-up closes |
| `timePicker` | `time_input` | typed `HH:MM` or a stepped, filterable list |
| `colorPicker` | `color_picker` | saturation/brightness area, hue slider, hex field, quick swatches from the color scheme; committed when the pop-up closes |

The components send the same values as before (indices, ISO dates, `HH:MM`, `#rrggbb`), so the D side
did not change. Pop-ups get the class `.st-popup` and follow the design style via `assets/designs.css`.
To add a control: build it in `ui.js` from `openPopup` and the shared listbox renderer, style it with
tokens in `style.css`, and add per-design rules where the design needs them.

## Accessible colors

`applyTheme()` derives contrast-safe tokens from each color scheme (and from user overrides):
`--text` and `--text-muted` are adjusted to reach 4.5:1 on every surface (including primary-tinted ones),
`--primary-strong` is the primary color darkened/lightened until its text (`--on-primary`) reaches 4.5:1
(used for filled buttons, chips, selected items), and `--primary-ink` is the primary color adjusted for
use as text (links, active tabs, accents). The brand `--primary` itself stays for borders, rings and
decoration.

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
3. Add styles to `assets/style.css`, using the theme tokens (`var(--primary)`, ...). If a design style
   needs different chrome for it, add scoped rules to `assets/designs.css` (see [Theming](theming.md#writing-your-own-design-contributors)).
4. Add an `AppTest` unit test (`tests/unit/apptests.d`) and a Playwright check (`tests/e2e/specs/`).
5. Regenerate the docs: `python3 tools/gen_api_docs.py`.

## App extensions

Apps can register color schemes, design styles and native elements ([Extending](extending.md)).

- **Registries:** `theme.d` keeps the app's schemes and designs next to the built-in lists
  (`builtinPresets()`, `builtinDesigns()`); `themePresets()` / `designStyles()` return both.
  `extensions.d` keeps the elements. The registries are `__gshared` behind one mutex
  (`g_extLock`), because sessions run on worker threads. `serve` registers the `config.toml`
  entries, then freezes the registries (later registrations throw).
- **Assets:** the design CSS and element CSS are combined at startup into `_stcore/ext.css`; each
  element's script is served on its own as `_stcore/ext/<name>.js`, so a syntax error in one does not
  stop the others (each is also wrapped in a function with a `try` that logs runtime errors with
  the element's name). `serveIndex` links them with a content hash (cached as immutable), only when
  there are any.
- **Frontend:** `window.StreamlitD.registerElement(name, def)` fills a registry in `app.js`.
  `RENDERERS.custom` draws `kind: "custom"` elements with it (or an error box when nothing was
  registered), and updates them in place through `def.render(...).update`. Widget values use
  `widgetChanged` / `triggerWidget`, like the built-in widgets.

## Vendored libraries

marked, Vega/Vega-Lite/Vega-Embed, Plotly.js, KaTeX, Leaflet, highlight.js and Swagger UI live in
`assets/vendor/`. Swagger UI (`vendor/swagger-ui/`) is embedded only when the API docs are compiled
in, so `gen_assets.py` keeps it in a separate list. Their licenses are listed in
[`assets/vendor/licenses/README.md`](../assets/vendor/licenses/README.md). After adding or
updating files there, run `python3 tools/gen_assets.py`.

## Repository tools

| Tool | Purpose |
|---|---|
| `run-tests.sh` | unit tests, e2e tests and doc snippet compilation |
| `tools/gen_assets.py` | regenerate the embedded asset list |
| `tools/gen_favicon.js` + `tools/gen_favicon.py` | render `assets/favicon.svg` to the PNG / Apple touch / `.ico` favicons |
| `tools/gen_api_docs.py` | regenerate `docs/api-reference.md` |
| `tools/check_doc_snippets.py` | compile every D snippet in `docs/` and check links |
| `tests/e2e/screenshots.js` + `tools/optimize_images.py` | regenerate `docs/images/` |
