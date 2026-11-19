# streamlitd examples

Runnable apps, from a ten-line hello world to multi-page business apps. Run any of them with:

```sh
cd examples/hello && dub run --compiler=ldc2
```

Then open <http://localhost:8501> (the `prod` example is at <http://localhost:8501/app/>).

> **Demo login: `alice` / `streamlitd-demo`** — the same in every example that has a login.
>
> - `auth` and `helpdesk` have alice in their `.streamlitd/secrets.toml`; sign in right away
>   (in `helpdesk`, `bob` is an agent with the same password).
> - `accounts` and `todo` let people sign up: on the login page choose **Create one** and sign up
>   with this login. In `accounts`, the first account becomes the administrator.

The small examples show one area each in a single `app.d`. The larger ones are split into modules,
with their own tests: [docs/examples.md](../docs/examples.md) walks through them and how to
structure an app like them. Every example also runs in the end-to-end tests.

## Small examples

### hello
The smallest app: a title, a text input, a button, session state and a sidebar.

![hello](../docs/images/hello.png)

### widgets
Every input widget (text, numbers, sliders, selects, dates, colours, …), layout containers, forms,
status elements, and the extra elements on the **More** tab.

![widgets](../docs/images/widgets.png)

### data
`DataFrame`, sortable and searchable tables, the data editor, every chart type, uploads, downloads
and images.

![data](../docs/images/dataframe.png)

### multipage
Top navigation with a section, breadcrumbs, a header bar, a banner, a footer, a menu button,
pagination, a chat UI and query parameters.

![multipage](../docs/images/chat-dark.png)

### themes
A gallery of the design styles, color schemes and light/dark modes, with the viewer's appearance
menu.

![themes](../docs/images/designs-light.png)

### fragments
`st.fragment` with partial reruns and auto-refresh, updates pushed by events (`refreshFragments`,
`refreshWhen`), `st.dialog`, `st.status`, pills, segmented controls and feedback.

![fragments](../docs/images/fragments.png)

### extras
LaTeX, highlighted code, Plotly, maps and custom components.

![extras](../docs/images/math-code.png)

### prod
A production setup: `config.toml`, secrets, a base URL path (`/app/`), worker threads (a busy
session doesn't block the others).

![prod](../docs/images/example-prod.png)

### auth
Login with users from `secrets.toml` (**alice / streamlitd-demo**) and single sign-on (the "Mock SSO"
button works only in the tests, which start a mock provider), a user menu, and an admin panel.

![auth](../docs/images/login.png)

### accounts
Sign-up without making password hashes by hand: the first account (sign up as **alice /
streamlitd-demo**) becomes the administrator. Later sign-ups need an invite. Also roles, a page for
one role, the account page, and the admin panel.

![accounts](../docs/images/example-accounts.png)

### tutorial
The sales dashboard built step by step in the [tutorial](../docs/tutorial.md).

![tutorial](../docs/images/tutorial.png)

### api
A dashboard and a JSON REST API on the same port, sharing their data
([API endpoints](../docs/api-endpoints.md)). Try `curl http://localhost:8501/api/todos`.

![api](../docs/images/example-api.png)

### custom
The app's own color schemes, design style and native widgets (a star rating), registered in D and
in `config.toml` ([Extending](../docs/extending.md)).

![custom](../docs/images/example-custom.png)

### business
A purchasing dashboard: KPI tiles with trends, configured and tree tables, a folding sidebar with
badges, link cards, a notification feed, an order calendar, exports built on click.

![business](../docs/images/example-business.png)

## Larger apps

Described in detail in [docs/examples.md](../docs/examples.md).

### helpdesk
Tickets and customers for a support team. Sign in as **alice / streamlitd-demo** (admin and agent) or
bob (agent, same password). A ticket table with a detail panel, nested dialogs, live updates
between agents, a JSON API, user administration.

![helpdesk](../docs/images/example-helpdesk.png)

### planning
Purchase planning: a yearly plan edited in a table and saved after a review, plan vs fact as a tree,
a delivery calendar, a CSV import wizard.

![planning](../docs/images/example-planning.png)

### todo
A TODO app: sign up (as **alice / streamlitd-demo**, or anyone) and get your own lists. Quick add with
`#tags` and `!priority`, filters, bulk actions, edit dialogs.

![todo](../docs/images/example-todo.png)

### gantt
A project planner: phases, tasks and milestones on a Gantt chart, dependencies and their warnings,
edit dialogs, a table view.

![gantt](../docs/images/example-gantt.png)

### monitor
A live operations monitor: a background producer pushes metrics to every open page; alerts with
rules and a live badge; a slow source checked off the event loop.

![monitor](../docs/images/example-monitor.png)
