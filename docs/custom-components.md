# Custom components

## Static HTML and iframes

<!-- wrap -->
```d
st.components.html(`<div style="padding:8px;border:1px dashed #999">Hello from <b>HTML</b></div>`, height: 60);
st.iframe("https://dlang.org", height: 400, scrolling: true);
st.html("<b>inline, trusted HTML</b>");        // no iframe: rendered in the page itself
```

`components.html` renders in a sandboxed iframe (`allow-scripts`, no same-origin). Scripts run
there but cannot touch the app page.

## Bidirectional components

A bidirectional component is a web page (HTML/JS/CSS) that receives arguments from D and sends
a value back, like a widget. streamlitd uses **Streamlit's component protocol**, so frontends
written for Streamlit (with `streamlit-component-lib`) work unchanged, as long as their
arguments and values are JSON.

### D side

<!-- compile -->
```d
import streamlitd;

__gshared Component counter;

shared static this()
{
    // a directory containing index.html (+ JS/CSS), served at <base>/_components/counter/
    counter = declareComponent("counter", path: "counter");
    // alternatives: declareComponent("x", html: "<html>...</html>")  or  (url: "http://localhost:3001") for a dev server
}

void app(St st)
{
    auto args = Json.emptyObject;
    args["label"] = "Click the button";
    auto v = counter(st, args, key: "c1", default_: Json(["count": Json(0)]));
    st.write("The component says:", v["count"]);
}

mixin StreamlitMain!app;
```

- `counter(st, args, key:, default_:, height:)` draws the component into `st` (any container)
  and returns its current value, or `default_` until the component sends one.
- The value persists across reruns like any widget value. With `key:` it is also in
  `st.session[key]`.
- With a `key:`, changing `args` sends a new `render` message to the same iframe; the component
  keeps its internal state. Without a key, the args are part of the component's identity, so
  changed args create a fresh component (reloaded iframe, value back to `default_`), as in Streamlit.

### Frontend side (no build tools needed)

`counter/index.html`:

```html
<button id="btn">Click me</button> <span id="label"></span>
<script>
  const send = (type, data) =>
    window.parent.postMessage(Object.assign({ isStreamlitMessage: true, type }, data || {}), "*");
  let count = 0;
  window.addEventListener("message", (e) => {
    if (e.data.type !== "streamlit:render") return;
    const { args, theme, disabled } = e.data;      // args from D; theme: design, colorScheme, base, colors
    document.getElementById("label").textContent = args.label;
    document.body.style.color = theme.textColor;
  });
  document.getElementById("btn").onclick = () =>
    send("streamlit:setComponentValue", { value: { count: ++count }, dataType: "json" });
  send("streamlit:componentReady", { apiVersion: 1 });
  send("streamlit:setFrameHeight", { height: 56 });
</script>
```

### Protocol

| Direction | Message | Fields |
|---|---|---|
| component → app | `streamlit:componentReady` | `apiVersion` |
| app → component | `streamlit:render` | `args` (JSON), `dfs` (always empty), `disabled`, `theme` (`base`, `primaryColor`, `backgroundColor`, `secondaryBackgroundColor`, `textColor`, `font`, plus streamlitd's `design` and `colorScheme`) |
| component → app | `streamlit:setComponentValue` | `value`, `dataType: "json"` |
| component → app | `streamlit:setFrameHeight` | `height` in pixels (ignored when `height:` was given in D) |

Component → app messages carry `isStreamlitMessage: true`. `render` is sent after `componentReady`,
whenever `args` change, and when the design style, color scheme or mode changes.

### Reusing Streamlit components

Most Streamlit components ship a built frontend directory (often `frontend/build`). Point
`declareComponent(name, path: ".../frontend/build")` at it and pass the same keyword
arguments the Python wrapper would pass, as a JSON object. This is not supported:

- **Arrow/DataFrame arguments** (`dfs`). Pass data as JSON records instead (`df.toRecords()`).
- **Binary (`bytes`) values** sent back from the component.

## Security

Bidirectional component iframes use `allow-scripts allow-same-origin` (as in Streamlit) and
are served from the app's own origin, so they can access the app page. Only use components
you trust. `components.html` is sandboxed without same-origin access.
