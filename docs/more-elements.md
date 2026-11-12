# More elements and widgets

Elements that business apps often need and that Streamlit does not have (or only through
third-party components). They follow the color scheme, mode and design style like the built-in
ones; `examples/widgets` shows all of them in its **More** tab.

The page's own building blocks (top navigation, header bar, footer, banners, user menu,
breadcrumbs) are in [Layout & navigation](layout-and-navigation.md#app-shell-header-bar-footer-and-banners).

| Element | Call |
|---|---|
| [Menu button](#menu-button) | `string menuButton(label, items, ...)` |
| [Pagination](#pagination) | `size_t pagination(totalItems, pageSize, ...)` |
| [Card](#card) | `St card(title, subtitle, image, icon)` |
| [Stepper](#stepper) | `stepper(steps, current, orientation)` |
| [Loading placeholder](#loading-placeholder) | `skeleton(lines, height)` |
| [Timeline](#timeline) | `timeline(TimelineItem[])` |
| [Avatar](#avatar) | `avatar(name, image, size)` |
| [Details](#details) | `details(string[2][])`, `details(Json)` |
| [Tags input](#tags-input) | `string[] tagsInput(label, value, suggestions, maxTags, ...)` |
| [Tree select](#tree-select) | `string[] treeSelect(label, TreeNode[], value, multi, ...)` |
| [Date range](#date-range) | `DateRange dateRangeInput(label, value, minValue, maxValue, ...)` |
| [Copy button](#copy-button) | `copyButton(text, label, icon)` |

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

Labels and values of one record, side by side (stacked on phones). Values are Markdown. A JSON
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

Copies the text to the clipboard and shows "Copied ✓"; the app does not rerun. Browsers only
offer the clipboard API on HTTPS and localhost; on plain HTTP a fallback is used, which most
browsers still allow after a click.
