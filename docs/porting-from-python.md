# Porting a Python Streamlit app

Most Streamlit apps port almost line by line. This page walks through a typical app and then
lists the differences that need thought.

## A worked example

**Python** (`app.py`):

```python
import pandas as pd
import streamlit as st

st.set_page_config(page_title="Orders", layout="wide")

@st.cache_data(ttl=600)
def load(path):
    return pd.read_csv(path)

df = load("orders.csv")

with st.sidebar:
    status = st.multiselect("Status", ["new", "paid", "shipped"], default=["paid"])
    min_total = st.slider("Minimum total", 0, 1000, 100)

view = df[df.status.isin(status) & (df.total >= min_total)]

c1, c2 = st.columns(2)
c1.metric("Orders", len(view))
c2.metric("Revenue", f"${view.total.sum():,.0f}")

st.bar_chart(view.groupby("status", as_index=False)["total"].sum(), x="status", y="total")
st.dataframe(view, hide_index=True)

if st.button("Export"):
    st.download_button("Download CSV", view.to_csv(index=False), "orders.csv")
```

**D** (`source/app.d`):

<!-- compile -->
```d
import streamlitd;
import std.algorithm : canFind;
import std.format : format;

DataFrame load(string path)
{
    return DataFrame.readCsv(path);
}

void app(St st)
{
    st.setPageConfig(title: "Orders", layout: Layout.wide);

    auto df = cacheData!(load, 600)("orders.csv");

    string[] statuses;   // not `status`: inside `with (st.sidebar)` that name means st.status
    int minTotal;
    with (st.sidebar)
    {
        statuses = multiselect("Status", ["new", "paid", "shipped"], ["paid"]);
        minTotal = slider("Minimum total", 0, 1000, 100);
    }

    auto view = df.filter((Row r) =>
        statuses.canFind(r.get!string("status")) && r.get!double("total") >= minTotal);

    auto c = st.columns(2);
    c[0].metric("Orders", cast(long) view.length);
    c[1].metric("Revenue", format("$%,.0f", view.sum("total")));

    st.barChart(view.groupBy("status", ["total"], "sum"), x: "status", y: ["total"]);
    st.dataframe(view, hideIndex: true);

    if (st.button("Export"))
        st.downloadButton("Download CSV", view.toCsv(), "orders.csv");
}

mixin StreamlitMain!app;
```

What changed:

| Python | D | Why |
|---|---|---|
| module-level script | `void app(St st)` + `mixin StreamlitMain!app` | D needs a function; the mixin generates `main` |
| `@st.cache_data(ttl=600)` decorator | `cacheData!(load, 600)(args)` at the call site | D has no decorators; the template wraps the call |
| `with st.sidebar:` + assignments | `with (st.sidebar) { ... }` with variables declared before | D's `with` block has its own scope for declarations |
| pandas boolean indexing | `df.filter((Row r) => ...)` | DataFrame API; `r.get!T("col")` gives typed access |
| `f"{x:,.0f}"` | `format("%,.0f", x)` | `std.format` |
| `default=` keyword | 3rd positional argument | Same order as the Python parameters; named works too: `default_:` |
| `y="total"` | `y: ["total"]` | `y` is always a list of columns |

## Differences to know

### Named arguments and templates (LDC 1.36)

D supports named arguments like Python keywords. With LDC 1.36 they cannot be combined with
**implicit template instantiation**. That's why the widgets that accept any element type have
separate names (`radioOf!T`, `selectboxOf!T`, `multiselectOf!T`, `pillsOf!T`, …), and the
type must be given explicitly when you use named arguments:

<!-- wrap -->
```d
auto n = st.radioOf!int("Size", [1, 2, 3], horizontal: true);       // OK
auto s = st.radio("Size", ["S", "M", "L"], horizontal: true);       // string version, no ! needed
```

### Names inside `with` blocks

Inside `with (st.sidebar) { ... }`, the names of `St` methods (`status`, `text`, `title`, `map`,
`table`, `image`, `code`, `form`, …) take precedence over your variables and functions. The
compiler reports "with symbol … is shadowing local symbol …". Rename the variable, or call
through the container explicitly (`side.text(...)`).

### Types are explicit

- `st.slider("x", 0, 100, 50)` returns `int`, and `st.slider("x", 0.0, 1.0, 0.5)` returns
  `double`. Pass `0.0` to get a float slider.
- `st.numberInput("n", 5)` returns `int`; `st.numberInput("n", 5.0)` or
  `st.numberInput("n")` returns `double`.
- Range sliders return a fixed-size array: `int[2] r = st.slider("r", 0, 10, [2, 8]);`.
- `selectbox` with `index: -1` and `chatInput` return `null` when there's no value. Test with
  `if (s is null)` or `if (auto p = st.chatInput(...))`.

### Session state is typed

Python: `st.session_state.count += 1`. D:
`st.session["count"] = st.session.get!int("count") + 1;`. Any D value can be stored, including
class objects such as database connections. Values stay on the server.

### Callbacks are delegates

Python: `st.button("x", on_click=reset, args=(1,))`. D:
`st.button("x", onClick: () { reset(1); });`. The closure captures what it needs.

### No `**kwargs` pass-through

D cannot forward arbitrary keyword arguments. Wrapper functions should declare the parameters
they need, or take an options struct.

### pandas → DataFrame

`DataFrame` covers the usual dashboard needs: load, filter, sort, select, group by with
sum/mean/count/min/max, summaries, CSV export. For heavy analytics, compute with D arrays
(`std.algorithm`) or in your database, then build a `DataFrame` for display with
`DataFrame.fromStructs`.

### Charts

| Python library | streamlitd |
|---|---|
| `st.line_chart` & co. | same, Vega-Lite based |
| Altair | `st.vegaLiteChart(chart.to_json())`: build the same spec as JSON |
| Plotly | `st.plotlyChart(figure JSON)`, from `fig.to_json()` or built in D |
| matplotlib `st.pyplot` | not supported: render to PNG/SVG elsewhere and use `st.image`, or switch to Vega-Lite/Plotly |
| pydeck | not supported: use `st.map` (Leaflet) or a custom component |

### Multipage apps

Python's `pages/` folder convention does not exist. Use `st.navigation([Page(&fn, "Title")])`
(the modern Streamlit API) and put each page in a function, or a module.

### Config and secrets

`.streamlit/config.toml` and `.streamlit/secrets.toml` are read as they are. Unsupported
options are ignored with a warning. See [Configuration](configuration.md).

### Execution and performance

Each script run executes on a worker thread, so CPU-heavy code doesn't block other users. D code is
typically much faster than Python, and the app starts instantly. There is no "Rerun on save":
recompile and restart (`dub run`), and the browser reconnects by itself.

## Feature coverage

Not available yet:

- `st.connection`
- `column_config`
- dataframe and chart selection events (except Plotly)
- `st.pyplot`, `st.pydeck_chart`
- `st.camera_input` / `st.audio_input`
- Arrow data in components
- hot reload

For everything else, see the [cheat sheet](cheatsheet.md).
