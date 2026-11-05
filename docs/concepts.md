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
is drawn.

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

- Use `st.sleep(seconds)` instead of `Thread.sleep`. It yields, and it lets a newer event
  interrupt the run.
- **Global mutable state** (`__gshared` variables, module-level caches you write yourself) is
  shared between threads. Protect it with a `Mutex`, or use `cacheData`/`cacheResource`, which
  are thread-safe.
- `--script-threads 0` runs every script on the event-loop thread as fibers, which is simpler
  to debug. Then one CPU-bound session does delay the others.

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
