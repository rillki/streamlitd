# Layout & navigation

Every layout call returns a new `St` (or an array of them) that draws into the container.
Use the returned object directly, or with `with`:

<!-- wrap -->
```d
auto left = st.columns(2)[0];
left.write("via the object");
with (st.container(border: true))
    write("via with");
```

## Sidebar

<!-- wrap -->
```d
st.sidebar.title("Filters");
with (st.sidebar)
{
    auto year = selectbox("Year", ["2023", "2024"]);
    write("Selected", year);
}
```

The sidebar appears as soon as something is drawn into it. Users can collapse it, and
`setPageConfig(initialSidebarState: "collapsed")` starts it collapsed.

## Columns

<!-- wrap -->
```d
auto c = st.columns(3);                                         // equal widths
c[0].metric("Temperature", "70 °F", "1.2 °F");
auto w = st.columns([2.0, 1], gap: "large", verticalAlignment: "center", border: true);
w[0].write("twice as wide");
```

On narrow screens (phones), columns stack vertically.

## Tabs, expanders, containers, popovers

<!-- wrap -->
```d
auto t = st.tabs(["Chart", "Data"]);
t[0].write("first tab");
t[1].write("second tab");

with (st.expander("Show details", expanded: false))
    write("hidden until opened");

auto box = st.container(border: true, height: 200);  // height > 0: scrollable
box.write("inside a bordered, scrollable container");

with (st.popover("Settings"))
    checkbox("Advanced mode");
```

Tabs keep their selection across reruns, and expanders keep their open/closed state.

![tabs, expander, container](images/layout.png)

## Placeholders: `st.empty`

`st.empty()` reserves one slot. Every call on it **replaces** the content, which is handy for
progress messages:

<!-- wrap -->
```d
auto slot = st.empty();
slot.info("Loading...");
st.sleep(0.5);
slot.success("Done");          // replaces the info box
```

## Forms

<!-- wrap -->
```d
auto f = st.form("order", clearOnSubmit: true, border: true);
auto item = f.selectbox("Item", ["Coffee", "Tea"]);
auto qty = f.numberInput("Quantity", 1, minValue: 1);
if (f.formSubmitButton("Order", type: "primary"))
    st.success("Ordered " ~ item);
```

Widgets in a form do not rerun the app until the submit button is pressed. See
[Core concepts](concepts.md#forms).

![a form](images/forms.png)

## Dialogs

A dialog is a modal window. It usually opens from a button and runs as a fragment, so its widgets
rerun only the dialog:

<!-- wrap -->
```d
if (st.button("Edit profile"))
    st.dialog("Edit profile", (St d) {
        auto name = d.textInput("Display name", st.session.get!string("name", "Ann"));
        if (d.button("Save", type: "primary"))
        {
            st.session["name"] = name;
            st.rerun();               // a full rerun closes the dialog
        }
    }, width: "small");
```

- The user can close it with ×, Escape or a click outside (`dismissible: false` prevents that).
- A dialog stays open while its own widgets are used, and closes on the next full rerun in which
  it isn't opened again.

![dialog](images/dialog.png)

## Status containers

<!-- wrap -->
```d
auto s = st.status("Downloading data...", expanded: true);
s.write("Fetched 3 files");
s.update(label: "Done", state: "complete", expanded: 0);   // states: running, complete, error
```

`StatusContainer` behaves like a container (`s.write`, `with (s) { ... }`) and adds `update`.

## Fragments

`st.fragment((St f) { ... }, runEvery: seconds)` draws a part of the page that reruns
independently. See [Core concepts → Fragments](concepts.md#fragments).

![fragments, status and newer widgets](images/fragments.png)

## Chat layout

<!-- wrap -->
```d
foreach (m; st.session.get!(string[][])("history"))
    st.chatMessage(m[0]).markdown(m[1]);
if (auto prompt = st.chatInput("Ask something"))
{
    st.chatMessage("user").markdown(prompt);
    st.chatMessage("assistant").markdown("Echo: " ~ prompt);
    st.session["history"] = st.session.get!(string[][])("history") ~ [["user", prompt], ["assistant", "Echo: " ~ prompt]];
}
```

A `chatInput` called on the main area is pinned to the bottom of the page. The names `"user"` and
`"assistant"` get default avatars; pass `avatar: "🦊"` for your own.

![chat](images/chat-dark.png)

## Multipage apps

<!-- compile -->
```d
import streamlitd;

void home(St st)
{
    st.title("Home");
    st.pageLink("reports", "Go to reports", "📊");
    if (st.button("Open settings"))
        st.switchPage("Settings");
}

void reports(St st) { st.title("Reports"); }
void settings(St st) { st.title("Settings"); }

void app(St st)
{
    st.setPageConfig(title: "My app");
    auto page = st.navigation([
        Page(&home, "Home", "🏠"),
        Page(&reports, "Reports", "📊"),                 // URL: /reports
        Page(&settings, "Settings", "⚙️", "config"),    // custom URL path: /config
    ]);
    // code here runs on every page (shared header, auth checks, ...)
    page.run(st);
}

mixin StreamlitMain!app;
```

- The first page (or the one with `isDefault: true`) is served at `/`. The others get a URL
  slug of their title, or the given `urlPath`.
- `navigation(..., position: "hidden")` hides the sidebar menu, for apps that navigate only
  with `pageLink`/`switchPage`.
- Deep links (`/reports`) and the browser back/forward buttons work.
- Widget state belongs to the page. Leaving a page forgets its widgets' values (as in
  Streamlit). Use `st.session` to share values between pages.

### Top navigation and sections

`position: "top"` puts the page links in a bar at the top of the page instead of the sidebar.
Pages with the same `section` are grouped: under a small heading in the sidebar, or in a dropdown
in the top bar (like Streamlit's `st.navigation({"Reports": [...]})`). Keep a section's pages next
to each other.

<!-- no-compile -->
```d
auto page = st.navigation([
    Page(&home, "Home", "🏠"),
    Page(&sales, "Sales", "💰", section: "Reports"),
    Page(&stock, "Inventory", "📦", section: "Reports"),
    Page(&settings, "Settings", "⚙️"),
], position: "top");
```

On narrow screens (phones) the top bar shows the current page's title instead; it opens one menu
with every page, grouped by section. Links and menus work with the keyboard (↓ opens a section,
arrows move, Enter opens the page, Esc closes) and Ctrl/Cmd-click opens a page in a new tab.

### Breadcrumbs

<!-- wrap -->
```d
st.breadcrumbs();                                        // from st.navigation: Home › Reports › Sales
st.breadcrumbs(["Customers", "ACME", "Invoices"], ["customers"]);  // explicit trail
```

Without arguments, the trail is built from `st.navigation` (call it first): the default page, the
page's section, then the page itself. With arguments, each item that has a URL path is a link to
that app page (a page's `urlPath`); the others are plain text. The last item is the current position.

## App shell: header bar, footer and banners

Besides the main area and the sidebar, a page has three more places to draw into (streamlitd only):

<!-- wrap -->
```d
st.banner("**Maintenance** tonight from 22:00 to 23:00.", "warning");   // above the main content
if (st.topbar.button("Help"))                                            // right side of the header bar
    st.toast("Read the docs at ...");
st.footer.caption("ACME Analytics · version 1.4 · © 2026");             // under the main content
```

- **`st.topbar`** is a container in the header bar, next to the rerun and settings buttons. It is
  meant for a few small items: buttons, `menuButton`, `userMenu`. When it has content (or the
  navigation is at the top), the header bar gets a background in every design.
- **`st.footer`** is a container under the main content of every page. Like the sidebar, it is
  hidden while empty.
- **`st.banner(body, type, dismissible, key, icon)`** shows a notice across the top of the main
  content (`type`: `info`, `success`, `warning`, `error`; the body is Markdown). A viewer can
  close a dismissible banner; it then stays closed in that browser tab until its text changes,
  or, with a `key`, until the key changes (so fixing a typo does not show it again).

Draw them in the code that runs for every page (before or after `page.run(st)`), so they appear
on all pages.

### User menu

<!-- wrap -->
```d
auto picked = st.userMenu(["Profile", "Billing", "-", "Help"]);
if (picked == "Profile")
    st.switchPage("profile");
```

`st.userMenu` shows the signed-in user in the header bar: their picture (OIDC `picture` claim) or
initials, and their name. It opens a menu with your items (`"-"` is a separator), **Account
settings** (for accounts in the user store: name, email and password on `/auth/account`; turn it
off with `account: false`) and **Log out** (`logout: false` hides it).
It returns the item picked in this run, otherwise null, like a button. Signed out, it shows a
**Log in** button; without `[auth]` configured it shows nothing. See [Authentication](authentication.md).
`rerun: true` and `appearance: true` add **Rerun** and **Appearance…** items (see below).

### Header controls: rerun and appearance

The header's ⟳ (rerun the app) and ⚙ (the viewer's [appearance panel](theming.md#the-viewer-appearance-menu))
can stay there, move into one ⋮ menu, or leave the header so the app places them itself.

```toml
# .streamlitd/config.toml
[ui]
rerunButton = "menu"       # "header" (default) | "menu" | "hidden"
settingsButton = "hidden"  # "header" (default) | "menu" | "hidden"
rerunShortcut = true       # the R key reruns the app, also when the button is hidden
```

- **`header`:** the icon in the header (the default).
- **`menu`:** a ⋮ button in the header with **Rerun** and **Appearance…**. It shows only the
  items set to `menu`.
- **`hidden`:** not in the header. Place them yourself, wherever you like:

<!-- wrap -->
```d
st.setPageConfig(rerunButton: "hidden", settingsButton: "hidden");   // this app only (default: [ui])
st.sidebar.settingsButton();                  // "⚙ Appearance": opens the panel next to it
st.footer.rerunButton("Refresh data", "🔄");   // reruns the whole app
st.userMenu(["Profile"], rerun: true, appearance: true);   // or as user-menu items
```

The appearance panel opens next to whatever opened it (also inside a popover or dialog) and stays
inside the window; Esc or a click elsewhere closes it.

**Other ways to set it:**
- environment: `STREAMLITD_UI_RERUNBUTTON`, `STREAMLITD_UI_SETTINGSBUTTON`,
  `STREAMLITD_UI_RERUNSHORTCUT`;
- command line: `--rerun-button`, `--settings-button`, `--no-rerun-shortcut`;
- `st.setPageConfig(rerunButton:, settingsButton:)` overrides `[ui]` until changed.

When the app does not let viewers change the appearance at all (`[theme] allowSwitch = false`,
`allowThemeSwitch: false`), ⚙, its menu item and `st.settingsButton()` are not shown anywhere.

## Query parameters

<!-- wrap -->
```d
auto qp = st.queryParams;
auto tab = qp.get("tab", "overview");     // ?tab=details
if (st.button("Show details"))
    qp["tab"] = "details";                 // updates the browser URL (no reload)
if ("debug" in qp)
    st.write("debug mode");
```

## Page configuration

<!-- wrap -->
```d
st.setPageConfig(title: "Sales", icon: "📈", layout: Layout.wide,
    initialSidebarState: "expanded", theme: "ocean");
```

`icon` sets the browser-tab favicon. It can be an emoji (`"📈"`), an `http(s)://` or `data:` URL, or a
**local image file** such as `"assets/logo.png"`; streamlitd serves the file itself. The wide layout uses the full browser width.

## Favicon

![the default streamlitd favicon](images/favicon.png)

Which icon a page shows, from highest priority to lowest:

1. **The app sets it in a run**: `st.setPageConfig(icon: ...)` or `st.setFavicon(...)`.
2. **The current page's icon** in a multipage app (`Page(&fn, "Reports", "📊")`), when the app sets none.
3. **The app-wide favicon** from `[server] favicon = "logo.svg"`, `--favicon logo.svg` or
   `STREAMLITD_SERVER_FAVICON`. It is also served at `/favicon.ico`.
4. **streamlitd's own icon** (above), shipped as SVG, PNG, Apple touch icon and `.ico`.

<!-- wrap -->
```d
st.setFavicon("🚀");                                    // emoji
st.setFavicon("https://dlang.org/favicon.ico");         // URL
st.setFavicon(cast(const(ubyte)[]) `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle cx="5" cy="5" r="5" fill="teal"/></svg>`, "image/svg+xml");
```

## Logo

<!-- wrap -->
```d
st.logo("https://dlang.org/images/dlogo.svg", link: "https://dlang.org");
```

The logo appears at the top of the sidebar. While the sidebar is hidden (the app draws nothing
into it) or collapsed, it appears in the top-left corner of the page instead.
