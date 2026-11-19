# Core concepts

## The rerun model

A streamlitd app is one function:

<!-- compile -->
```d
import streamlitd;

void app(St st)
{
    auto n = st.slider("n", 1, 10, 3);
    st.write("n squared is", n * n);
}

mixin StreamlitMain!app;
```

- Each browser tab gets its own **session**.
- When the tab connects, and **after every interaction**, the session calls `app` again from
  the top.
- Each call produces a fresh list of elements. The browser updates what changed and removes
  what was not drawn this time.
- Elements left over from the previous run fade out while a long run is in progress
  ("stale" elements).

This is exactly Streamlit's model. Code reads top to bottom, like a script, and the UI is a
function of the inputs.

Consequences:

- **Local variables do not survive a rerun.** Use [session state](#session-state) for that.
- **Expensive work runs on every rerun.** Cache it with [`cacheData`](#caching) or isolate it in a
  [fragment](#fragments).
- **Order matters.** A widget's value is available from the line where it is created. Values
  computed further down are only visible on the next run.

## `St`: the delta generator

The `st` parameter (type `St`) is where elements go. Container calls return another `St` that
writes into the container:

<!-- wrap -->
```d
st.write("main area");
st.sidebar.write("sidebar");
auto cols = st.columns(2);
cols[0].write("left column");
with (st.expander("Details"))      // D's version of Python's `with st.expander(...)`
    write("inside the expander");
```

Inside `with (x) { ... }`, calls without a receiver go to `x`. You can also pass containers to
your own functions: `void drawKpis(St box) { box.metric(...); }`.

## Widgets and their identity

Widgets (`button`, `slider`, `textInput`, ...) **return their current value**:

<!-- wrap -->
```d
auto city = st.selectbox("City", ["Almaty", "Astana"]);   // "Almaty" on the first run
if (st.button("Go"))                                       // true only in the run caused by the click
    st.write("Going to", city);
```

The browser remembers each widget's value under a **widget id**. By default the id is derived
from the widget type, its label and its significant parameters (options, min/max, ...).
Consequences:

- Two widgets with the same type and label in the same run raise a `DuplicateWidgetID` error,
  shown in the page. Give one of them a `key:`.
- Changing a widget's label or options creates a *new* widget, which starts at its default.
- A widget not drawn in a run is forgotten. Its value is cleared, as in Streamlit.

With `key: "name"` the id is the key, and the value is also available as `st.session["name"]`.

## Session state

`st.session` is a per-tab key/value store that survives reruns. It is Streamlit's
`st.session_state`.

<!-- wrap -->
```d
st.session.setDefault("count", 0);               // only sets it the first time
if (st.button("Increment"))
    st.session["count"] = st.session.get!int("count") + 1;
st.write("Count:", st.session.get!int("count"));
```

| Operation | Code |
|---|---|
| set | `st.session["k"] = value;` (any D type: ints, strings, arrays, structs, class objects) |
| get, typed | `st.session.get!int("k")`, `st.session.get!int("k", 42)` (default if missing) |
| get, raw | `st.session["k"]` returns a `std.variant.Variant` (throws if missing) |
| exists | `"k" in st.session`, `st.session.has("k")` |
| init once | `st.session.setDefault("k", 0)` |
| delete | `st.session.remove("k")`, `st.session.clear()` |

Numeric values convert between types (`get!double` on an `int` works). Values stay on the
server and are never sent to the browser.

### Widgets bound to session state

<!-- wrap -->
```d
auto name = st.textInput("Name", key: "name");   // value is mirrored to st.session["name"]
if (st.button("Reset"))
{
    st.session["name"] = "";    // takes effect on the next run...
    st.rerun();                 // ...so rerun right away
}
```

Assigning `st.session[key]` from code overrides what the user typed the next time the widget
is drawn. `st.resetWidgets("name", ...)` goes back to the widgets' defaults.

A keyed widget keeps its value in `st.session` even in runs where it is not drawn (on another page,
in a closed branch), so it comes back with the viewer's choice.

## The request: `st.context`

<!-- wrap -->
```d
auto c = st.context;
auto token = c.cookie("airop_token");          // e.g. single sign-on from a portal
st.write("Language:", c.locale, "· time zone:", c.timezone, "· from", c.ip);
if (c.header("X-Requested-With") == "intranet")
    st.caption("Opened from the intranet");
```

| Field | Value |
|---|---|
| `header(name)`, `headers` | request headers of the page's connection (any case) |
| `cookie(name)`, `cookies` | its cookies (also HttpOnly ones: the app runs on the server) |
| `ip` | the client address (behind a proxy with `[server] trustProxy`, the address the proxy reports) |
| `locale` | the browser's language, e.g. `ru-RU` |
| `timezone`, `timezoneOffset` | the browser's time zone, e.g. `Asia/Almaty`, and minutes east of UTC |
| `url` | the page's address in the browser |

The headers and cookies are those of the WebSocket connection, sent when the page opens. The
language, time zone and URL come with every browser message. In tests, use
`at.setContext(RequestContext(...))`.

## Callbacks

Widgets take `onChange:` (or `onClick:` for buttons). The callback runs **before** the next
run of `app`, so the run already sees its effects:

<!-- wrap -->
```d
st.session.setDefault("clicks", 0);
st.button("Click", onClick: () { st.session["clicks"] = st.session.get!int("clicks") + 1; });
st.write("Clicks:", st.session.get!int("clicks"));     // already up to date
```

## Buttons are "true once"

`st.button` returns `true` only in the run triggered by the click. To remember that something
was clicked, store it in session state. The same applies to `formSubmitButton`,
`downloadButton` and `chatInput`; `chatInput` returns `null` when nothing was submitted.

## Forms

Widgets inside `st.form` don't trigger reruns. Their values are sent together when the
submit button is pressed:

<!-- wrap -->
```d
auto f = st.form("signup", clearOnSubmit: true);
auto email = f.textInput("Email");
auto plan = f.selectbox("Plan", ["Free", "Pro"]);
if (f.formSubmitButton("Sign up"))
    st.success("Welcome, " ~ email ~ " (" ~ plan ~ ")");
```

Pressing Enter in a text input submits the form; pass `enterToSubmit: false` to disable that.
Forms cannot be nested.

## Interruption

If the user interacts while a run is in progress, the old run is abandoned at its next `st.*`
call and a new run starts. That keeps the UI responsive. Long loops without any `st.*` call
cannot be interrupted, but in threaded mode they no longer block other users (see
[Threads](#threads-and-blocking)).

## Stopping and rerunning

| Call | Effect |
|---|---|
| `st.stop()` | end the current run here; elements drawn so far stay |
| `st.rerun()` | start a new full run immediately |
| `st.rerun(scope_: "fragment")` | inside a fragment run: rerun only that fragment |

## Fragments

A fragment is a part of the page that reruns independently:

<!-- wrap -->
```d
auto factor = st.slider("Factor (reruns everything)", 1, 5, 1);
st.fragment((St f) {
    auto n = f.slider("Value (reruns only this box)", 0, 100, 10);
    f.write("Result:", n * factor);
});
st.fragment((St f) { f.write("Updated every 5 seconds"); }, runEvery: 5);
```

- A widget inside a fragment reruns only that fragment's function.
- A fragment's function is a closure, so it sees the variables of the full run that created it
  (`factor` above). A full rerun refreshes those values.
- `runEvery: seconds` reruns the fragment periodically, for live dashboards.
- [`st.dialog`](layout-and-navigation.md#dialogs) bodies are fragments too.

### Updates driven by events

`runEvery` alone reruns a fragment on every tick, even when nothing changed, and a change waits
for the next tick. Three additions let the data decide (streamlitd only):

| | What it does | Called from |
|---|---|---|
| `refreshWhen: () => bool` | asked when a `runEvery` run is due; `false` skips it (nothing runs, nothing is sent) until the next period | the server's event loop: keep it light (a version counter, a file's modification time); no blocking I/O |
| `refreshOn: "orders"` + `refreshFragments("orders")` | reruns every fragment subscribed to the topic, in every open browser tab, at once | anywhere, any thread: API routes, file watchers, queue consumers, background tasks |
| `auto live = st.fragment(...); live.refresh()` | reruns that one fragment in that one tab, at once | anywhere, any thread; does nothing once the tab is closed or the fragment is no longer drawn |

<!-- compile -->
```d
import streamlitd;
import core.atomic : atomicLoad, atomicOp;

shared long g_version;            // bumped whenever the orders change

void app(St st)
{
    // pushed: reruns as soon as an order is saved, in every open tab
    st.fragment((St f) { f.metric("Open orders", atomicLoad(g_version)); }, refreshOn: "orders");

    // polled, but only when something changed: asked every 10 s, runs when the version moved
    auto seen = new long;
    *seen = -1;
    st.fragment((St f) {
        *seen = atomicLoad(g_version);
        f.write("Report for version", *seen);
    }, runEvery: 10, refreshWhen: () => atomicLoad(g_version) != *seen);
}

void routes(URLRouter r)
{
    r.post("/api/orders", (HTTPServerRequest req, HTTPServerResponse res) {
        // ... save the order ...
        atomicOp!"+="(g_version, 1);
        refreshFragments("orders");     // the open pages update now
        res.writeJsonBody(["ok": true]);
    });
}

mixin StreamlitMain!(app, routes);
```

- `refreshOn` takes several topics separated by commas (`"orders, stock"`).
- The two styles combine: push with `refreshFragments` for no delay, and keep a slow `runEvery`
  with `refreshWhen` as a safety net in case an event is missed.
- A push that arrives while the fragment is running does not interrupt it: the run finishes, then
  the fragment runs once more (several pushes in between count as one). A widget interaction, as
  before, restarts it at once.
- A fragment rerun is the same as one started by a widget inside it: its function runs with the
  values of the full run that drew it, and only its part of the page is sent.
- `examples/fragments` has a live demo: a background thread calls `refreshFragments`.

## Caching

<!-- no-compile -->
```d
DataFrame load(string path) { return DataFrame.readCsv(path); }
// ...
auto df = cacheData!load("data.csv");          // computed once per distinct argument list
auto pool = cacheResource!connectDb(url);       // one shared object (connections, models)
```

| | `cacheData!(fn, ttlSeconds = 0, maxEntries = 0)` | `cacheResource!fn` |
|---|---|---|
| shared between sessions | yes | yes |
| returns | a **copy** (`.dup`) when the type supports it (arrays, `DataFrame`) | the same object |
| expiry | `ttlSeconds` (0 = never), `maxEntries` (oldest is evicted) | never |
| clearing | `cacheClear!fn()`, `clearAllCaches()` | same |

Arguments are part of the cache key (serialized to JSON or `to!string`).

## Threads and blocking

By default each run executes on a vibe.d **worker thread** (`--script-threads`, default: one
per CPU core). A CPU-heavy run therefore does not block other users. Worker threads have a vibe.d
event loop, so vibe.d drivers (PostgreSQL, MongoDB, HTTP client) work inside `app`.

Several sessions share one worker thread (each run is a vibe.d task, a fiber). A run that waits in
a vibe.d call (database query, HTTP request, `st.sleep`) lets the others continue. A run that
**blocks the thread** stops the other sessions on that thread until it returns. Examples are a
non-vibe driver (ODBC, a C library), `std.net.curl`, `Thread.sleep`, or a long loop.

**`blocking`** runs such a call on a thread of its own while the session waits, so the others go
on:

<!-- wrap -->
```d
import core.thread : Thread;
import core.time : msecs;
auto rows = blocking(() {                 // e.g. an ODBC query
    Thread.sleep(200.msecs);
    return ["a", "b"];
});
st.write("Rows:", rows.length);
```

The load test (`tests/load/load.mjs`) checks this: while one session blocks for 1.5 s, 199 others
finish their runs in about 40 ms.

**What is shared between users:**

| Per session (browser tab) | Shared by everybody |
|---|---|
| widget values, `st.session`, the current page, `st.user`, `st.context` | `cacheData`/`cacheResource` caches, module-level `shared`/`__gshared` variables, files and databases |

- **Module-level variables are thread-local in D.** `int visits;` at module level is a separate
  variable in every worker thread, so different users would see different values. For data
  shared between users:
  - declare it `shared` (with `core.atomic`) or `__gshared`, and protect it with a `Mutex`;
  - or use `cacheResource` / `cacheData`, which are thread-safe.
- **Caches compute once.** When several sessions ask a `cacheData`/`cacheResource` for the same
  missing value at the same time, one computes it and the others wait for the result: one
  connection pool, one slow query. If the computation throws, the next caller tries again.
- Use `st.sleep(seconds)` instead of `Thread.sleep`. It yields, and it lets a newer event
  interrupt the run.
- `--script-threads 0` runs every script on the event-loop thread as fibers, which is simpler
  to debug. Then one CPU-bound session does delay the others.

## User text in Markdown

`st.markdown`, `st.write`, labels, captions, toasts, feeds, timelines and dialog titles read
**Markdown**. Text that users typed is Markdown too, unless you escape it. `![x](http://…)` in a
ticket title then becomes an image that every other viewer's browser loads: a tracking pixel that
tells a stranger who looked, and when. Links and `:red[…]` "official" text can be faked the same
way. Raw HTML and `javascript:` links are always neutralised, but Markdown itself is not.
It matters when one person's text is shown to others (tickets, comments, names in a shared app).
Echoing people's own input back to them, as the `hello` example does, harms no one.
`escapeMarkdown` shows such text exactly as it was typed:

<!-- wrap -->
```d
auto title = st.textInput("Title");
st.subheader("Ticket: " ~ escapeMarkdown(title));        // shown as typed, never formatted
st.markdown("**" ~ escapeMarkdown(title) ~ "** was saved"); // your formatting, their text
```

Tables (`st.dataframe`, `st.table`), inputs and the navigation show text as text already.

## Errors

Any exception or D `Error` thrown in `app` (for example a `RangeError` from an out-of-bounds index in
a debug build) is shown in the page with its message and stack trace, as in Streamlit. The
elements drawn before the error stay visible.

## Media and files

Images, downloads and uploads are kept in memory per session:

- Media you send (`st.image(bytes)`, `downloadButton`) is served from `_media/<hash>` and
  released when no run references it any more.
- Files uploaded with `fileUploader` stay available until the user removes them or the session
  ends.
