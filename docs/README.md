# streamlitd documentation

streamlitd lets you build data apps in **D** the way you build them in Python with
[Streamlit](https://streamlit.io). You write a plain function that runs from top to bottom on
every interaction. You get a single self-contained binary that serves the web UI.

## Start here

1. [Getting started](getting-started.md): install the toolchain and run your first app in 5 minutes.
2. [Tutorial](tutorial.md): build a sales dashboard step by step.
3. [Core concepts](concepts.md): reruns, widget state, session state, callbacks, forms and fragments.
4. [Example apps](examples.md): five larger apps to read and copy, and how to structure your own.

## Guides

| Guide | What it covers |
|---|---|
| [Layout & navigation](layout-and-navigation.md) | sidebar, columns, tabs, expanders, forms, dialogs, status, multipage apps (sidebar or top navigation, sections, breadcrumbs), header bar, footer, banners, user menu, query params |
| [More elements and widgets](more-elements.md) | menu button, pagination, card (also as a link), stepper, loading placeholder, timeline, avatar, details, tags, tree select, date range, copy button, KPI with a trend, empty state, legend, proportion bar, feed, calendar grid |
| [Data & charts](data-and-charts.md) | `DataFrame`, tables (column configuration, totals, colours, selection, tree rows), data editor, line/bar/area/scatter charts, Vega-Lite, Plotly, maps, downloads built on click |
| [Theming](theming.md) | 8 design styles (terminal, retro, win95, XP, …) × 8 color schemes × light/dark, custom colors and fonts |
| [Configuration](configuration.md) | `config.toml`, environment variables, command-line flags, `secrets.toml` |
| [Deployment](deployment.md) | release builds, systemd, Docker and docker-compose, reverse proxies, scaling |
| [Authentication](authentication.md) | sign-up with automatic password hashing, roles, admin panel, account page, invites, login limits, CLI user commands, users in secrets.toml, OIDC single sign-on (Google, Entra ID, Keycloak…), `st.user` |
| [Custom components](custom-components.md) | static HTML/iframes and bidirectional JS components |
| [Extending streamlitd](extending.md) | your own color schemes, design styles and native widgets/elements, in D or `config.toml` |
| [JSON API endpoints](api-endpoints.md) | FastAPI-style REST endpoints served next to the app, sharing its login and data |
| [Testing](testing.md) | headless `AppTest` unit tests and Playwright end-to-end tests |
| [Example apps](examples.md) | a helpdesk, purchase planning, a TODO app, a Gantt planner and a live monitor: what each shows, how a larger app is structured, pitfalls |
| [Porting from Python](porting-from-python.md) | a worked migration of a Python Streamlit app and common pitfalls |

## Reference

| Page | |
|---|---|
| [Cheat sheet (Python → D)](cheatsheet.md) | every Streamlit call and its streamlitd equivalent |
| [API reference](api-reference.md) | every public function with its signature (generated from the sources) |
| [Troubleshooting & FAQ](troubleshooting.md) | common problems and their fixes |
| [Architecture](architecture.md) | how it works inside: modules, protocol, frontend (for contributors) |

## Examples

The [`examples/`](../examples) folder contains runnable apps; [examples/README.md](../examples/README.md) shows each with a screenshot. Apps with a login use **alice / streamlitd-demo**. Each one is used by the end-to-end tests:

| Example | Shows |
|---|---|
| `hello` | the smallest app: text, input, button, session state, sidebar (with an appearance button) |
| `widgets` | every input widget, layout containers, forms, status elements, and the extra elements (tab **More**) |
| `data` | DataFrame, dataframe/table/data editor, all chart types, upload/download, images |
| `multipage` | top navigation with a section, breadcrumbs, header bar, banner, footer, menu button, pagination, chat UI, query params |
| `themes` | design gallery: design styles, color schemes, modes and the viewer appearance menu |
| `fragments` | `st.fragment`, auto-refresh, updates pushed by events (`refreshFragments`, `refreshWhen`), `st.dialog`, `st.status`, pills/segmented/feedback |
| `extras` | LaTeX, code highlighting, Plotly, maps, custom components |
| `prod` | `config.toml`, secrets, base URL path, worker threads |
| `auth` | users in secrets.toml and OIDC login, user menu, admin panel for SSO users (login: alice / streamlitd-demo) |
| `accounts` | sign-up without manual hashes (the first account is admin: sign up as alice / streamlitd-demo), invites, roles, account page |
| `tutorial` | the app built in the [tutorial](tutorial.md) |
| `api` | a dashboard plus a JSON REST API on the same port ([API endpoints](api-endpoints.md)) |
| `custom` | the app's own color schemes, design style and native widgets ([Extending](extending.md)) |
| `business` | a purchasing dashboard: KPI trends, configured and tree tables, folding sidebar with badges, link cards, feed, exports built on click, `st.context` |

Five larger, multi-module apps with their own tests are described in [Example apps](examples.md):

| Example | Shows |
|---|---|
| `helpdesk` | tickets and customers (login: alice / streamlitd-demo): roles, a ticket table with a detail panel, nested dialogs, live updates between agents, a JSON API |
| `planning` | purchase planning: a plan editor with a review dialog and a conflict check, plan vs fact as a tree, a delivery calendar, a CSV import wizard |
| `todo` | sign-up (as alice / streamlitd-demo) and lists per person, quick add, filters, bulk actions, edit dialogs, tabs kept in sync |
| `gantt` | a Gantt chart on the calendar grid: phases, milestones, dependencies and their warnings, edit dialogs, a table view |
| `monitor` | a background producer pushing to all pages, KPI sparklines, alerts with rules and a live badge, a slow source run with `blocking` |

Run any of them with:

```sh
cd examples/data && dub run --compiler=ldc2
```

Then open <http://localhost:8501>. The `prod` example is served under
<http://localhost:8501/app/>, because its `.streamlitd/config.toml` sets `baseUrlPath`.
