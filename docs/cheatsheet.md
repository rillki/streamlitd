# Cheat sheet: Streamlit (Python) → streamlitd (D)

`st` is the `St` your `app` function receives. Optional parameters are passed by name, like
Python keyword arguments: `st.slider("x", 0, 10, 5, step: 2, key: "s")`. Python's
`snake_case` names become `camelCase`.

## App skeleton

| Python | D |
|---|---|
| `import streamlit as st` | `import streamlitd;` |
| script body | `void app(St st) { ... }` plus `mixin StreamlitMain!app;` |
| `streamlit run app.py` | `dub run --compiler=ldc2` (or `./app`) |
| `streamlit run app.py --server.port 8080` | `./app --port 8080` |
| `st.set_page_config(page_title=, page_icon=, layout="wide", initial_sidebar_state=)` | `st.setPageConfig(title:, icon:, layout: Layout.wide, initialSidebarState:, design:, colorScheme:)` |

## Text

| Python | D |
|---|---|
| `st.title("T", anchor=, help=)` | `st.title("T", anchor:, help:)` |
| `st.header("H", divider="blue")`, `st.subheader` | `st.header("H", divider: "blue")`, `st.subheader` (also `anchor:`, `help:`) |
| `st.markdown(md, unsafe_allow_html=True)` | `st.markdown(md, unsafeAllowHtml: true)` |
| `:red[text]`, `:blue-background[text]` in markdown | supported |
| `$x^2$` / `$$...$$` in markdown | supported (KaTeX) |
| `st.caption`, `st.text`, `st.divider()` | `st.caption`, `st.text`, `st.divider()` |
| `st.code(src, language="python", line_numbers=True)` | `st.code(src, "python", lineNumbers: true)` (syntax highlighted) |
| `st.latex(r"e^{i\pi}")` | ``st.latex(`e^{i\pi}`)`` |
| `st.html("<b>x</b>")` | `st.html("<b>x</b>")` (trusted HTML) |
| `st.write(a, b, df, obj)` | `st.write(a, b, df, obj)`: strings → markdown, numbers → code, `DataFrame` → table, structs/arrays/AAs/`Json` → JSON viewer, exceptions → error box |
| `st.badge("New", color="green")` | `st.badge("New", color: "green")` |

## Status and feedback

| Python | D |
|---|---|
| `st.success/info/warning/error(msg, icon=)` | same names, `icon:` |
| `st.exception(e)` | `st.exception(e)` |
| `st.toast("Saved", icon="✅")` | `st.toast("Saved", icon: "✅")` |
| `with st.spinner("Loading"): work()` | `{ auto s = st.spinner("Loading"); work(); }` or `st.spinner("Loading", { work(); });` |
| `bar = st.progress(0); bar.progress(50, text=)` | `auto bar = st.progress(0); bar.progress(50, "text");` (int 0..100 or double 0..1) |
| `with st.status("Working") as s: ...; s.update(label=, state="complete")` | `auto s = st.status("Working"); s.write(...); s.update(label: "Done", state: "complete");` |
| `st.balloons()`, `st.snow()` | same |
| `st.metric("A", 42, "+3", delta_color="inverse", border=True)` | `st.metric("A", 42, "+3", deltaColor: "inverse", border: true)` |
| `st.json(obj, expanded=False)` | `st.json(jsonValueOrText, expanded: false)`; any D value (struct, AA, array): `st.jsonOf!T(obj, expanded: false)` or `st.jsonOf(obj)` |

## Input widgets

| Python | D | Returns |
|---|---|---|
| `st.button("Go", on_click=f, type="primary", use_container_width=True, icon=)` | `st.button("Go", onClick: () { f(); }, type: "primary", useContainerWidth: true, icon:)` | `bool` |
| `st.link_button("Docs", url)` | `st.linkButton("Docs", url)` | |
| `st.download_button("CSV", data, "f.csv", "text/csv")` | `st.downloadButton("CSV", data, "f.csv", "text/csv")` (`string` or `ubyte[]` data) | `bool` |
| `st.checkbox("A", value=True)`, `st.toggle` | `st.checkbox("A", true)`, `st.toggle` | `bool` |
| `st.radio("R", opts, index=1, horizontal=True, captions=)` | `st.radio("R", opts, 1, horizontal: true, captions:)` | `string` |
| `st.selectbox("S", opts, index=None, placeholder=)` | `st.selectbox("S", opts, index: -1, placeholder:)` | `string` (`null` if none) |
| `st.multiselect("M", opts, default=[...], max_selections=2)` | `st.multiselect("M", opts, ["a"], maxSelections: 2)` | `string[]` |
| options of any type + `format_func=` | `st.radioOf!T`, `selectboxOf!T`, `multiselectOf!T`, `selectSliderOf!T`, `pillsOf!T`, `segmentedControlOf!T` with `formatFunc:` | `T` / `T[]` |
| `st.pills("P", opts)` / `selection_mode="multi"` | `st.pills("P", opts)` / `st.pillsMulti("P", opts, default)` | `string` / `string[]` |
| `st.segmented_control(...)` | `st.segmentedControl(...)` / `st.segmentedControlMulti(...)` | `string` / `string[]` |
| `st.feedback("stars")` | `st.feedback("stars")` (`"thumbs"`, `"faces"`, `"stars"`) | index, `-1` = none |
| `st.slider("S", 0, 100, 25, step=5)` | `st.slider("S", 0, 100, 25, step: 5)` | `int` (also `long`, `double`) |
| `st.slider("R", 0.0, 1.0, (0.2, 0.8))` | `st.slider("R", 0.0, 1.0, [0.2, 0.8])` | `double[2]` (also `int[2]`) |
| `st.select_slider("Size", opts, value="M")` | `st.selectSlider("Size", opts, 2)` (index) | `string` |
| `st.number_input("N", value=5, min_value=0)` | `st.numberInput("N", 5, minValue: 0)` (int value → `int`) | `int` |
| `st.number_input("X", value=1.5, step=0.5)` | `st.numberInput("X", 1.5, step: 0.5)` | `double` |
| `st.text_input("T", type="password", max_chars=20, placeholder=)` | `st.textInput("T", type: "password", maxChars: 20, placeholder:)` | `string` |
| `st.text_area("A", height=200)` | `st.textArea("A", height: 200)` | `string` |
| `st.date_input("D", date(2024,1,2), min_value=, max_value=)` | `st.dateInput("D", Date(2024,1,2), minValue:, maxValue:)` | `std.datetime.Date` |
| `st.time_input("T", time(9,30), step=900)` | `st.timeInput("T", TimeOfDay(9,30), stepSeconds: 900)` | `TimeOfDay` |
| `st.color_picker("C", "#ff0000")` | `st.colorPicker("C", "#ff0000")` | `string` |
| `st.file_uploader("F", type=["csv"])` | `st.fileUploader("F", ["csv"])` | `UploadedFile` or `null` (`.name`, `.type`, `.size`, `.bytes`, `.text`) |
| `st.file_uploader(..., accept_multiple_files=True)` | `st.fileUploaderMulti(...)` | `UploadedFile[]` |
| `st.chat_input("Say")` | `if (auto p = st.chatInput("Say")) ...` | `string` or `null` |
| `st.data_editor(df, num_rows="dynamic", disabled=[...])` | `st.dataEditor(df, numRows: "dynamic", disabled: [...])` | edited `DataFrame` |

Common widget parameters: `key:`, `help:`, `onChange:` (`onClick:` for buttons), `disabled:`
and `labelVisibility: "visible" | "hidden" | "collapsed"`.

## Layout

| Python | D |
|---|---|
| `st.sidebar.x(...)` / `with st.sidebar:` | `st.sidebar.x(...)` / `with (st.sidebar) { x(...); }` |
| `c1, c2 = st.columns(2)` / `st.columns([2,1], gap="large", vertical_alignment="center", border=True)` | `auto c = st.columns(2); c[0].x(...)` / `st.columns([2.0, 1], gap: "large", verticalAlignment: "center", border: true)` |
| `t1, t2 = st.tabs(["A", "B"])` | `auto t = st.tabs(["A", "B"]);` |
| `with st.expander("More", expanded=True):` | `with (st.expander("More", expanded: true)) { ... }` |
| `st.container(border=True, height=300)` | `st.container(border: true, height: 300)` |
| `ph = st.empty(); ph.write(...)` | `auto ph = st.empty(); ph.write(...);` (each call replaces the content) |
| `with st.popover("Open"):` | `with (st.popover("Open")) { ... }` |
| `with st.form("f", clear_on_submit=True): ...; st.form_submit_button()` | `auto f = st.form("f", clearOnSubmit: true); ...; f.formSubmitButton("Send")` |
| `with st.chat_message("user"):` | `with (st.chatMessage("user")) { ... }` |
| `@st.dialog("Title")` + call | `st.dialog("Title", (St d) { ... }, width: "large")` |
| `@st.fragment(run_every=5)` + call | `st.fragment((St f) { ... }, runEvery: 5)` |

## Data and charts

| Python | D |
|---|---|
| `pd.read_csv("f.csv")` | `DataFrame.readCsv("f.csv")` / `DataFrame.fromCsv(text)` |
| `pd.DataFrame(records)` | `DataFrame.fromStructs(rows)`, `DataFrame.fromJson(records, ["col1", "col2"])` |
| `pd.DataFrame({"a": [...]})` | `new DataFrame().addColumn("a", [1, 2]).addColumn("b", ["x", "y"])` |
| `df.head(5)`, `df.tail()`, `df[["a","b"]]` | `df.head(5)`, `df.tail()`, `df.select("a", "b")` |
| `df[df.a > 3]` | `df.filter((Row r) => r.get!int("a") > 3)` |
| `df.sort_values("a", ascending=False)` | `df.sortBy("a", false)` |
| `df.groupby("k")["v"].sum().reset_index()` | `df.groupBy("k", ["v"], "sum")` (`sum`, `mean`, `count`, `min`, `max`) |
| `df["a"].sum()`, `.mean()` | `df.sum("a")`, `df.mean("a")`, `df.min`, `df.max` |
| `df.to_csv()` | `df.toCsv()` |
| `st.dataframe(df, height=, hide_index=True, column_order=)` | `st.dataframe(df, height:, hideIndex: true, columnOrder:)` |
| `st.table(df)` | `st.table(df)` |
| `st.line_chart(df, x="d", y=["a","b"], color=)` | `st.lineChart(df, x: "d", y: ["a", "b"], color:)` |
| `st.bar_chart(..., horizontal=True, stack=False)` | `st.barChart(..., horizontal: true, stack: false)` |
| `st.area_chart`, `st.scatter_chart(size=)` | `st.areaChart`, `st.scatterChart(size:)` |
| `st.vega_lite_chart(df, spec)` | `st.vegaLiteChart(spec, df)` (`Json` or JSON string) |
| `st.altair_chart(chart)` | `st.vegaLiteChart(chart.to_json())`: Altair produces Vega-Lite |
| `st.plotly_chart(fig, on_select="rerun")` | `st.plotlyChart(figJson, onSelect: "rerun")` returns the selection `Json` |
| `st.map(df, size=, color=, zoom=)` | `st.map(df, size: "radius_m", color: "#ff0000", zoom: 6)` |
| `st.image(img, caption=, width=)` | `st.image(bytes or path or url, caption:, width:)` |
| `st.audio`, `st.video` | `st.audio`, `st.video` (bytes, path or URL) |
| `st.logo("logo.png", link=)` | `st.logo("logo.png", link:)` |

## Control flow and state

| Python | D |
|---|---|
| `st.session_state.x = 1` / `st.session_state["x"]` | `st.session["x"] = 1;` / `st.session.get!int("x")` |
| `if "x" not in st.session_state:` | `if ("x" !in st.session)` or `st.session.setDefault("x", 0)` |
| `del st.session_state.x` | `st.session.remove("x")` |
| `st.rerun()`, `st.rerun(scope="fragment")` | `st.rerun()`, `st.rerun(scope_: "fragment")` |
| `st.stop()` | `st.stop()` |
| `time.sleep(1)` | `st.sleep(1)` |
| `@st.cache_data(ttl=600, max_entries=100)` | `cacheData!(fn, 600, 100)(args)` |
| `@st.cache_resource` | `cacheResource!fn(args)` |
| `fn.clear()` / `st.cache_data.clear()` | `cacheClear!fn()` / `clearAllCaches()` |
| `st.query_params["x"]`, `st.query_params["x"] = "1"` | `st.queryParams["x"]`, `st.queryParams["x"] = "1"` |
| `st.query_params.get("x", "d")`, `.clear()` | `st.queryParams.get("x", "d")`, `.clear()` |
| `st.secrets["db"]["user"]` | `st.secrets["db"]["user"].get!string` / `st.secrets.get!string("db.user")` |

## Multipage

| Python | D |
|---|---|
| `pg = st.navigation([st.Page(f, title=, icon=)]); pg.run()` | `auto pg = st.navigation([Page(&f, "Title", "📈")]); pg.run(st);` |
| `st.switch_page("pages/x.py")` | `st.switchPage("Title or url-path")` |
| `st.page_link("x", label=, icon=)` | `st.pageLink("url-path", "Label", "🏠")` |

## Users and authentication

| Python | D |
|---|---|
| `st.user.is_logged_in`, `st.user.name`, `st.user.email` | `st.user.isLoggedIn`, `st.user.name`, `st.user.email` (`sub`, `provider`, `claims`) |
| `st.login("google")`, `st.logout()` | `st.login("google")`, `st.logout()` |
| `[auth]` in `secrets.toml` | same format; see [Authentication](authentication.md) |

## Components

| Python | D |
|---|---|
| `components.html(html, height=200)` | `st.components.html(html, height: 200)` |
| `components.iframe(url, height=)` | `st.iframe(url, height:)` |
| `c = components.declare_component("c", path="build")` / `c(arg=1, key="k", default=0)` | `auto c = declareComponent("c", path: "build");` / `c(st, args, key: "k", default_: Json(0))` |

## Theming and configuration

| Python | D |
|---|---|
| `.streamlit/config.toml` | `.streamlitd/config.toml` (`.streamlit/config.toml` is read too) |
| `[theme] base="dark" primaryColor=...` | same keys, plus `scheme = "ocean"` and `design = "terminal"` (see [Theming](theming.md)) |
| (no equivalent) | `st.setTheme(design: "win95", scheme: "paper", mode: "dark")`: [8 design styles × 8 color schemes](theming.md) |
| `--theme.primaryColor=#f00` | `--theme.primaryColor=#f00` |
| `--server.baseUrlPath=/x` | `--base-url-path /x` |

## Testing

| Python | D |
|---|---|
| `at = AppTest.from_file("app.py").run()` | `auto at = new AppTest(&app).run();` |
| `at.text_input[0].input("x").run()` | `at.setValue("text_input", "Label", Json("x")).run();` |
| `at.button[0].click().run()` | `at.click("Label").run();` |
| `at.markdown[0].value` | `at.markdowns[0]`, `at.texts("text")`, `at.elements("metric")` |

## D idioms you will use

- **Named arguments** work for every non-template function: `st.button("Go", type: "primary")`.
  With LDC 1.36 they do **not** work together with implicit template instantiation. That is why
  generic widgets have explicit `...Of!T` names: write `st.radioOf!int("N", [1, 2, 3], horizontal: true)`.
- **Containers and `with`**: `with (st.sidebar) { header("x"); }`. To pass a container
  somewhere, pass the `St` itself: `void kpis(St box) { box.metric(...); }`.
- **Callbacks** are delegates: `onClick: () { st.session["n"] = 0; }`. They can use the
  surrounding variables.
- **Python `with` blocks** that run code (`with st.spinner():`) map to scoped values
  (`{ auto s = st.spinner("..."); ... }`) or delegate overloads (`st.spinner("...", { ... })`).
- **`null` strings** mean "nothing": `if (auto p = st.chatInput("Say"))` and
  `st.selectbox(..., index: -1)` return `null` when nothing is selected or submitted.
- **JSON values** use `vibe.data.json.Json`, re-exported by streamlitd:
  `Json(["a": Json(1)])`, `parseJsonString(text)`, `j["key"].get!string`.
- **Formatting**: `import std.format : format; format("%,.2f", x)` (the `,` adds thousands separators).
