# Extending streamlitd: your own color schemes, design styles and widgets

An app can add three kinds of things to streamlitd, either in D code or in `config.toml`:

| What | D code | `config.toml` |
|---|---|---|
| [Color scheme](#color-schemes) (a palette, light and dark) | `registerColorScheme(...)` | `[theme.schemes.<name>]` |
| [Design style](#design-styles) (the shape of the UI, as CSS) | `registerDesign(...)` | `[theme.designs.<name>]` |
| [Native element or widget](#native-elements-and-widgets) (rendered by your JavaScript) | `registerElement(...)` | `[elements.<name>]` |

They behave like the built-in ones: they appear in the viewer's appearance menu, work with
`Theme(...)`, `[theme] scheme`/`design` and `--color-scheme`/`--design`, and custom widgets work with
keys, `st.session`, callbacks, forms and fragments.

`examples/custom` uses all of them: the scheme `acme` and the element `badge` are registered in
D, and the scheme `dusk`, the design `neon` and the widget `rating` come from its config file.

**When to register.** Everything is registered before the server starts: in D, in a module
constructor (`shared static this()`) or in your own `main` before `serve`/`runMain`; config entries
are registered at startup. Registering later throws, because each browser tab receives the lists
when it connects. Names use `a-z`, `0-9`, `_` and `-`, and must not repeat a built-in name.

**Trust.** Design CSS and element JavaScript run in the app's own page, with full access to it.
Only register code you wrote or trust. Like streamlitd's own `static/` files, they are served
without a login even with `[auth] required`, so don't put secrets or private data in them; pass
data through `props` instead. For third-party UI, use the sandboxed
[iframe components](custom-components.md) instead.

## Color schemes

A scheme is a set of [theme tokens](theming.md#custom-colors-and-fonts) for light and for dark mode.
Give only what differs: the rest comes from a `base` scheme (`streamlit` by default).

<!-- compile -->
```d
import streamlitd;

shared static this()
{
	ThemeTokens both;                 // applies to light and dark mode
	both.primaryColor = "#0055aa";
	both.chartColors = ["#0055aa", "#ff8800", "#22aa55", "#aa3377", "#33bbee"];
	ThemeTokens dark;                 // wins over `both` in dark mode
	dark.primaryColor = "#4d9fff";
	dark.backgroundColor = "#0b1220";
	registerColorScheme("acme", "Acme Corp", both: both, dark: dark);   // base: "streamlit"
}

void app(St st) { st.title("Acme dashboard"); }

mixin StreamlitMain!app;
```

The same in `config.toml`:

```toml
[theme]
scheme = "acme"                 # make it the app's default

[theme.schemes.acme]
label = "Acme Corp"
base = "streamlit"              # tokens not given come from here
primaryColor = "#0055aa"        # both modes
chartColors = ["#0055aa", "#ff8800", "#22aa55"]

[theme.schemes.acme.dark]
primaryColor = "#4d9fff"
backgroundColor = "#0b1220"
```

- Colors are `#rgb` or `#rrggbb`. `linkColor` follows `primaryColor` unless you set it.
- `font`, `headingFont` and `codeFont` accept font stacks, and in config also Streamlit's
  `"sans serif"`, `"serif"` and `"monospace"`.
- Text contrast is checked as for the built-in schemes: text, links and text on primary-colored
  buttons are adjusted to reach 4.5:1 (see [Theming](theming.md#accessibility)).

## Design styles

A design changes the shape of the UI: borders, shadows, corners, fonts, chrome. It has two parts:

- **data:** a name and label, and optionally fonts, a corner radius and chart settings that the
  design forces (`DesignStyle`);
- **CSS:** rules that are all scoped by `:root[data-design="<name>"]`.

<!-- compile -->
```d
import streamlitd;

shared static this()
{
	DesignStyle neon;
	neon.name = "neon";
	neon.label = "Neon";
	neon.description = "Glowing outlines";
	neon.headingFont = fontMono;
	neon.baseRadius = "6px";
	neon.strokeWidth = 2.5;         // chart line width
	registerDesign(neon, css: `
:root[data-design="neon"] .st-btn { border: 1px solid var(--primary);
  box-shadow: 0 0 8px color-mix(in srgb, var(--primary) 45%, transparent); }
.dc-preview[data-design="neon"] .dc-btn { box-shadow: 0 0 5px var(--primary); }`);
	// or: registerDesign(neon, cssPath: "styles/neon.css");
}

void app(St st) { st.button("Glow"); }

mixin StreamlitMain!app;
```

```toml
[theme.designs.neon]
label = "Neon"
description = "Glowing outlines"
css = "styles/neon.css"         # relative to the working directory
headingFont = "monospace"
baseRadius = "6px"
strokeWidth = 2.5               # also barRadius, gridDash = [2, 3]
```

Rules for the CSS:

- **Scope every rule** with `:root[data-design="<name>"]`, so the design never changes the others.
  Unscoped rules are reported as a warning at startup. `@media`, `@supports`, `@keyframes` and
  `@font-face` are fine.
- **Take colors from the scheme tokens** (`--primary`, `--primary-strong`, `--on-primary`, `--bg`,
  `--bg2`, `--text`, `--text-muted`, `--border`, `--widget-bg`, `--chart-1` … `--chart-10`) and
  mix them with `color-mix()`, so the design works with every scheme in light and dark mode.
- **The menu card**: rules for `.dc-preview[data-design="<name>"]` and its `.dc-bar`, `.dc-btn` and
  `.dc-input` draw the design's preview card in the appearance menu.
- The classes the built-in designs use (`.st-btn`, `.st-input`, `.form`, `details.expander`,
  `.alert`, `.metric`, …) are listed in `assets/designs.css`; `assets/designs.css` is also the best
  source of examples. [Theming](theming.md#writing-your-own-design) explains the conventions.

## Native elements and widgets

A custom element is drawn directly in the page by JavaScript you register, like the built-in
elements. Compared with an [iframe component](custom-components.md) it follows the color scheme,
mode and design (its CSS can use the theme tokens), keeps focus and state across reruns, and its
value goes through the same path as built-in widgets.

### D side

<!-- compile -->
```d
import streamlitd;

shared static this()
{
	// files read at startup (relative to the working directory)
	registerElement("rating", jsPath: "ui/rating.js", cssPath: "ui/rating.css");
	// or compiled into the binary, with "stringImportPaths": ["ui"] in dub.json:
	//   registerElement("rating", js: import("rating.js"), css: import("rating.css"));
}

void app(St st)
{
	// a widget: returns its value (the default until the user picks one)
	int stars = st.customWidget!int("rating", "Your rating", 3, Json(["max": Json(5)]), key: "stars");
	st.write("Rated", stars);
	// the same renderer as a display-only element: shows 4 of 5 stars, not clickable
	st.customElement("rating", Json(["max": Json(5), "value": Json(4)]));
}

mixin StreamlitMain!app;
```

```toml
[elements.rating]
js = "ui/rating.js"             # required: it registers the renderer
css = "ui/rating.css"           # optional
```

`st.customWidget!T(name, label, default_, props, key, onChange, disabled, help, labelVisibility, trigger)`:

- **Always give `T` explicitly** (`customWidget!int`), so named arguments such as `key:` work.
- The browser's value is decoded into `T` on the server (any type vibe.d can deserialize from JSON:
  numbers, strings, arrays, structs). A value that does not decode gives `default_`.
- `props` (a JSON object) reaches the renderer as `el.props`. Like the arguments of built-in
  widgets, props are part of the widget's identity; give a `key` to keep the value when they change.
- `trigger: true` makes a button-like widget: `api.trigger(v)` returns `v` for that one run, and
  `default_` on every other run.
- In a form, values are sent with the form's submit button, as for built-in widgets. Trigger
  widgets act at once, also inside a form (like `st.button`).

`st.customElement(name, props)` shows something without a value.

An unregistered name throws, so typos show up as an error in the app.

### Browser side

The registered JavaScript calls `StreamlitD.registerElement` once. One renderer can serve both
`st.customWidget` and `st.customElement`: `el.id` is set only for widgets.

```js
StreamlitD.registerElement("rating", {
  // box: the element's container; el: the element (see below); api: helpers
  render(box, el, api) {
    if (el.id) box.appendChild(api.label());    // widgets: the standard label (help, labelVisibility)
    const row = document.createElement("div");
    box.appendChild(row);
    const draw = () => {
      const value = el.id ? el.value : el.props.value; // display-only: the value comes in props
      row.replaceChildren(...Array.from({ length: el.props.max || 5 }, (_, i) => {
        const b = document.createElement("button");
        b.type = "button";
        b.textContent = i < value ? "★" : "☆";
        b.disabled = !el.id || el.disabled;
        if (el.id) b.addEventListener("click", () => api.setValue(i + 1)); // send a value: the app reruns
        return b;
      }));
    };
    draw();
    return {
      update(next) { el = next; draw(); },      // optional: new value/props, same node (keeps focus)
      destroy() {},                             // optional: clean up timers, listeners
    };
  },
});
```

| `el` field | Meaning |
|---|---|
| `element` | the registered name |
| `id` | the widget id (widgets only; missing for `st.customElement`) |
| `props` | the `props` object from D |
| `value` | the current value (widgets only) |
| `label`, `help`, `labelVisibility`, `disabled` | as given in D (widgets only) |

| `api` | Meaning |
|---|---|
| `setValue(v)` | send a new value (JSON); the app reruns, or the form keeps it until submit (widgets only) |
| `trigger(v)` | for `trigger: true` widgets: rerun once with `v` (widgets only) |
| `label(forId?)` | the standard widget label element |
| `markdown(text)` | inline Markdown to HTML (as used for labels) |
| `theme` | `{ mode, scheme, design, token(name) }`, e.g. `api.theme.token("--primary")` |
| `onTheme(fn)` | called after the scheme, mode or design changes (CSS variables update by themselves; this is for canvas drawing) |

Without `update`, the element is drawn again from scratch when its value or props change.

The container gets `data-testid="st-custom-<name>"` (and `data-label` for widgets), which is handy
in Playwright tests. In [`AppTest`](testing.md), custom widgets have the kind `"custom"`:
`at.setValue("custom", "Your rating", Json(5))`, and `at.customElements("rating")` lists them.

Each element's script is loaded as its own file (`_stcore/ext/<name>.js`). If it has a syntax
error, throws, or never registers its renderer, that element shows an error box naming it, the
browser console has the details, and the other elements keep working.
