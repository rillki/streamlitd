# More elements and widgets

Elements that business apps often need and that Streamlit does not have (or only through
third-party components). They follow the color scheme, mode and design style like the built-in
ones. `examples/widgets` shows most of them in its **More** tab, and `examples/business` shows them
in a dashboard.

The page's own building blocks (top navigation, header bar, footer, banners, user menu,
breadcrumbs) are in [Layout & navigation](layout-and-navigation.md#app-shell-header-bar-footer-and-banners).

| Element | Call |
|---|---|
| [Menu button](#menu-button) | `string menuButton(label, items, ...)` |
| [Pagination](#pagination) | `size_t pagination(totalItems, pageSize, ...)` |
| [Card](#card) | `St card(title, subtitle, image, icon, key, link)` |
| [Stepper](#stepper) | `stepper(steps, current, orientation)` |
| [Loading placeholder](#loading-placeholder) | `skeleton(lines, height)` |
| [Timeline](#timeline) | `timeline(TimelineItem[])` |
| [Avatar](#avatar) | `avatar(name, image, size)` |
| [Details](#details) | `details(string[2][])`, `details(Json)` |
| [Tags input](#tags-input) | `string[] tagsInput(label, value, suggestions, maxTags, ...)` |
| [Tree select](#tree-select) | `string[] treeSelect(label, TreeNode[], value, multi, ...)` |
| [Date range](#date-range) | `DateRange dateRangeInput(label, value, minValue, maxValue, ...)` |
| [Copy button](#copy-button) | `copyButton(text, label, icon, help, url)` |
| [KPI with a trend](#kpi-with-a-trend) | `metric(..., chartData:, chartType:, caption:)` |
| [Empty state](#empty-state) | `emptyState(title, body, icon)` |
| [Legend](#legend) | `legend(LegendItem[], title)` |
| [Proportion bar](#proportion-bar) | `proportionBar(values, labels, colors, format)` |
| [Feed](#feed) | `feed(FeedItem[])` |
| [Calendar grid](#calendar-grid) | `GridEvent calendarGrid(GridRow[], GridItem[], start, end, unit, ...)` |
| Rerun / appearance buttons | `rerunButton(label, icon)`, `settingsButton(label, icon)`: the header's ⟳ and ⚙ anywhere ([Header controls](layout-and-navigation.md#header-controls-rerun-and-appearance)) |

## Menu button

<!-- wrap -->
```d
switch (st.menuButton("Export", ["CSV", "Excel", "-", "Print"], icon: "⬇️"))
{
    case "CSV": st.downloadButton("Download CSV", "a,b\n1,2", "data.csv"); break;
    case "Print": st.toast("Sent to the printer"); break;
    default: break;
}
```

A button that opens a menu of actions. It returns the item picked in this run, otherwise null,
like `st.button`. `"-"` is a separator. With the keyboard: ↓ or Enter opens it, arrows and a
letter move, Enter picks, Esc closes.

## Pagination

<!-- wrap -->
```d
import std.algorithm : min;
auto rows = new string[95];
auto page = st.pagination(rows.length, 20);              // 1-based
foreach (r; rows[(page - 1) * 20 .. min(page * 20, rows.length)])
    st.text(r);
```

Buttons ‹ 1 … 4 5 6 … 9 ›. The page stays within range when `totalItems` shrinks (for example
after a filter). Give a `key` when you have several on one page.

## Card

<!-- wrap -->
```d
auto cols = st.columns(3);
foreach (i, name; ["Revenue", "Orders", "Customers"])
{
    auto c = cols[i].card(name, "Last 30 days", icon: "📊");
    c.metric(name, "1,204", "+3%");
    c.button("Open " ~ name);
}
```

A framed box with an optional image (`image:` a URL), icon, title and subtitle. It returns its
body: put anything inside. Each design frames it like a bordered container.

`link:` makes the whole card a link, to an app page (its URL path) or an `https://` address. Buttons
and widgets inside it still work, and Ctrl-click opens the page in a new tab:

<!-- wrap -->
```d
with (st.card("Suppliers", "Plan and fact by brand", icon: "🏭", link: "suppliers"))
    caption("4 suppliers · 7 brands");
```

## Stepper

<!-- wrap -->
```d
auto steps = ["Account", "Address", "Payment"];
auto step = st.session.get!int("step", 0);
st.stepper(steps, step);                 // steps before `step` are done
if (st.button("Next", disabled: step >= steps.length))
{
    st.session["step"] = step + 1;
    st.rerun();
}
```

`current` is the index of the current step (`steps.length` = all done). `orientation:
"vertical"` lists the steps under each other.

## Loading placeholder

<!-- wrap -->
```d
auto ph = st.empty();
ph.skeleton(4);                          // grey shimmering lines while the data loads
st.sleep(0.5);                           // a slow query
ph.text("loaded");
```

`skeleton(lines)` or `skeleton(height: 200)` for a block (e.g. where a chart will be). The
shimmer stops for users who prefer reduced motion.

## Timeline

<!-- wrap -->
```d
st.timeline([
    TimelineItem("Order placed", "09:12", "Order **#1042**"),
    TimelineItem("Payment received", "09:14", null, "💳", "success"),
    TimelineItem("Shipped", "11:05", null, "🚚", "info"),
]);
```

`TimelineItem(title, time, body, icon, type)`: the body is Markdown, `type` (`info`, `success`,
`warning`, `error`) colors the marker.

## Avatar

<!-- wrap -->
```d
st.avatar("Ann Lee");                                   // initials "AL"
st.avatar("Bob", image: "https://example.com/bob.png", size: "large");
```

Sizes `small`, `medium`, `large`. The colors come from the theme, so the initials are readable in
every scheme. The user menu uses the same avatar.

## Details

<!-- wrap -->
```d
st.details([["Customer", "ACME Corp"], ["Contact", "Ann Lee"], ["Status", "**Active**"]]);
st.details(parseJsonString(`{"plan": "pro", "seats": 5}`));   // keys in alphabetical order
```

Labels and values of one record, side by side (stacked on phones). Values are Markdown.
`inline: true` puts the pairs in one row, a stat strip ("Suppliers: **4** Brands: **7** …"). A JSON
object keeps no key order, so its rows are sorted by key; use the `string[2][]` form for your
own order.

## Tags input

<!-- wrap -->
```d
string[] tags = st.tagsInput("Tags", ["d"], suggestions: ["charts", "reports", "vibe.d"], maxTags: 5);
```

Typed text becomes a tag on Enter or comma; Backspace in the empty field removes the last one.
While typing, matching `suggestions` are offered. Tags are trimmed, and empty or repeated ones
dropped, on the server too.

## Tree select

<!-- wrap -->
```d
string[] regions = st.treeSelect("Regions", [
    TreeNode("eu", "Europe", [TreeNode("de", "Germany"), TreeNode("fr", "France")]),
    TreeNode("us", "United States"),
], ["de"]);
```

A pop-up tree with search. With `multi` (the default), checking a node checks its whole subtree;
a node is included when all its children are (partly checked nodes show –). A parent id in
`value` (or in `st.session`) stands for its whole subtree, so `["eu"]` returns `["eu", "de", "fr"]`. The value is sent
when the pop-up closes (**Done**, Esc or a click outside), and lists the ids in tree order.
`multi: false` picks one node. Ids that are not in the tree are dropped; node ids must be unique.
Values set through `st.session[key]` are cleaned up the same way (this also applies to tags and
date ranges).
Keys: ↑/↓ move, → opens or goes to the first child, ← closes or goes to the parent, Space or
Enter checks.

## Date range

<!-- wrap -->
```d
DateRange r = st.dateRangeInput("Period", DateRange(Date(2026, 1, 1), Date(2026, 1, 31)));
st.write("From", r.start.toISOExtString, "to", r.end.toISOExtString);
```

The first click in the calendar picks the start, the second the end (in either order); you can
also type `2026-01-01 – 2026-01-31`. The result always has `start <= end` and stays within
`minValue`/`maxValue`. It defaults to today–today. (In Streamlit: `st.date_input` with a pair.)

## Copy button

<!-- wrap -->
```d
st.copyButton("https://reports.example.com/q3?region=eu", "Copy link");
```

Copies the text to the clipboard and shows "Copied ✓"; the app does not rerun. With `url: true`,
a path such as `/auth/reset?token=…` is copied as a full URL on the server the browser is on
(the admin panel uses this for invite and reset links). Browsers only
offer the clipboard API on HTTPS and localhost; on plain HTTP a fallback is used, which most
browsers still allow after a click.

## KPI with a trend

<!-- wrap -->
```d
st.metric("Fact", "5,510 €", "+4.2%", chartData: [4.8, 5.0, 5.1, 4.9, 5.3, 5.51], caption: "was 5,288 € last month",
    border: true);
st.metric("Debt", "1,135 €", "-12%", deltaColor: "inverse", chartData: [1.6, 1.4, 1.1], chartType: "area");
```

`chartData` draws a small chart under the value (`chartType`: `"line"`, `"bar"`, `"area"`), in the
theme's primary colour. `caption` adds a small line, e.g. the value it is compared with. Screen
readers hear "Trend from … to …".

## Empty state

<!-- wrap -->
```d
st.emptyState("No unread notifications", "New alerts appear here.", "📭");
```

A dashed box for "nothing here": when a filter matches nothing, or a list is empty.

## Legend

<!-- wrap -->
```d
st.legend([LegendItem("Overdue more than 14 days", "error"), LegendItem("Overdue", "warning"),
    LegendItem("Plan", "info", "line"), LegendItem("Fact")], "Colours");
```

Explains the colours of a table (`cellStyle`, `ColumnConfig.background`) or a chart. Colours are
tokens (`success`, `warning`, `error`, `info`, `muted`, `primary`), hex colours, or (when null) the
chart palette in order. Shapes are `square`, `circle`, `line` and `diamond`.

## Proportion bar

<!-- wrap -->
```d
st.proportionBar([1_135.0, 450.0, 2_100.0], ["Overdue", "Due this week", "Not due"],
    ["error", "warning", "success"], format: "%,.0f €");
```

A bar split in proportion to the values, with a legend that shows each value and its percentage
(which is also what screen readers read). `format` is a number format as in
[column configuration](data-and-charts.md#column-configuration-totals-and-colours).

## Feed

<!-- wrap -->
```d
st.feed([
    FeedItem("Payment overdue: **Initech**", "21 days past the due date.", "09:12", "error", true, null, ["Initech"]),
    FeedItem("Sync finished", "12,431 rows.", "yesterday", "success"),
]);
```

`FeedItem(title, body, time, type, unread, icon, badges)`: a list of notifications or alerts.
`type` colours the edge and picks the icon; unread items have a dot and a bold title. Combine it
with [pagination](#pagination) and a `segmentedControl("Show", ["Unread", "All"], required: true)`.

## Calendar grid

<!-- wrap -->
```d
import std.datetime : Date;
auto rows = [
    GridRow("acme", "ACME", null, "3 / 5 delivered", 0.6, 0.7),   // summary, progress, expected by today
    GridRow("rocket", "Rocket", "acme"),                          // under ACME
];
auto items = [
    GridItem("d1", "rocket", Date(2026, 11, 3), Date.init, "Delivery 1 · 400 €", 400, "dot", "success"),
    GridItem("d3", "rocket", Date(2026, 11, 24), Date.init, "Delivery 3 · 900 €", 900, "dot", "primary", true),
    GridItem("p1", "rocket", Date(2026, 11, 20), Date(2026, 11, 27), "Payment window", double.nan, null, "info"),
];
auto ev = st.calendarGrid(rows, items, Date(2026, 11, 1), Date(2026, 12, 31), key: "plan",
    summaryLabel: "Delivered", expanded: 1, focus: st.queryParams.get("focus"));
if (ev.kind == "item")
    st.write("Clicked", ev.item, "on", ev.date.toISOExtString);
```

A schedule: one row per `GridRow`, one column per day (or week, `unit: "week"`), with items placed on
it. Rows with a `parent` are shown under it when it is opened (`expanded:` levels open at first).

**Items** (`GridItem(id, row, start, end, label, value, shape, color, outline)`):
- a marker on its `start` day, or a span when it has an `end`;
- `value` sizes markers relative to the largest one;
- `shape`: `dot`, `square` or `diamond`;
- `color`: a token (`success`, `warning`, `error`, `info`, `muted`, `primary`) or a hex colour;
- `outline: true` draws it hollow (e.g. planned rather than done);
- more than three markers on one day collapse into "+N".

**Rows** (`GridRow(id, label, parent, summary, progress, expected)`):
- the summary column shows `summary` text and a bar for `progress` (0–1);
- `expected` puts a mark on that bar, e.g. how far along it should be by today.

**The grid:**
- the name and summary columns and the header stay in place while scrolling;
- weekends are shaded, the month starts are marked, and today is highlighted (`today:` overrides
  the date);
- the grid opens scrolled to today, and keeps its scroll position across reruns.

**Clicks** rerun the app and return a `GridEvent`, only in that run, like a button:

| `ev.kind` | Clicked | Fields |
|---|---|---|
| `"item"` | a marker or span | `ev.item`, `ev.row`, `ev.date` |
| `"row"` | a row's name | `ev.row` |
| `"cell"` | an empty day (or "+N") | `ev.row`, `ev.date` |

- **`focus:`** an item id: the grid scrolls to that item, opens its rows and highlights it once.
  This suits links from notifications (`?focus=d3`).
- **Keyboard:** one Tab stop; ←/→ move along a row, ↑/↓ to the nearest item in the next row,
  Enter opens.
- **Legend:** add one with [`st.legend`](#legend).
- **Tests:** `at.trigger("plan", Json([...]))` sends a click.
