# Testing

There are two layers:

1. **`AppTest`**: run your app function headless, without a browser or server. It is fast,
   and runs under `dub test`.
2. **End-to-end tests** with Playwright against the real server, for the frontend.

## Headless tests with `AppTest`

<!-- compile -->
```d
import streamlitd;
import std.conv : to;

void counterApp(St st)
{
    st.session.setDefault("n", 0);
    if (st.button("Add"))
        st.session["n"] = st.session.get!int("n") + 1;
    auto name = st.textInput("Name", "World");
    st.text("Hello " ~ name ~ " " ~ st.session.get!int("n").to!string);
}

unittest
{
    auto at = new AppTest(&counterApp).run();
    assert(at.texts("text") == ["Hello World 0"]);

    at.click("Add").run();
    at.setValue("text_input", "Name", Json("Ann")).run();
    assert(at.texts("text") == ["Hello Ann 1"]);
    assert(at.session.get!int("n") == 1);
}

void app(St st) { counterApp(st); }
mixin StreamlitMain!app;
```

`AppTest` drives the same session engine as the server. Widget values, keys, callbacks, forms,
fragments and dialogs behave as in the browser.

| Method | Purpose |
|---|---|
| `new AppTest(&fn)` | wrap a `void fn(St)` (or a delegate) |
| `.run()` | run until no rerun is pending; returns `this` |
| `.setValue(kind, label, Json)` | change a widget (kinds: `text_input`, `slider`, `selectbox`, `checkbox`, ...); selection widgets take the **index** |
| `.setValueById(id, Json)` | same, by widget id |
| `.click(label, kind = "button")` | click a button (`"form_submit_button"`, `"download_button"`) |
| `.submitForm(buttonLabel, [id: value])` | submit a form with values |
| `.chat(message)` | submit the chat input |
| `.elements(kind)` | elements of the last run in page order, as `Json` (`heading`, `markdown`, `alert`, `metric`, `dataframe`, `block`, …) |
| `.texts(kind)`, `.markdowns`, `.headings`, `.alerts` | text bodies of an element kind |
| `.widget(kind, label)` | the widget element (`["value"]`, `["options"]`, …) |
| `.exceptions` | errors shown in the page |
| `.messages(type)` | other messages of the last run (`toast`, `navigation`, `set_theme`, …) |
| `.lastStatus` | `RunStatus.ok`, `error`, `stopped` |
| `.session` | the session state |

Element kinds and their fields are the ones the server sends to the browser (see
[Architecture](architecture.md#protocol)). Use `writeln(at.elements())` to inspect them while
writing tests.

Run the tests with `dub test --compiler=ldc2`.

## End-to-end tests (Playwright)

The repository's `tests/e2e` folder shows the setup. `playwright.config.js` builds and starts
each example app on its own port, and the specs drive a real browser:

```js
const { test, expect } = require("@playwright/test");

test("greets", async ({ page }) => {
  await page.goto("http://127.0.0.1:8701/");
  await page.waitForFunction(() => document.body.dataset.running === "0" && +document.body.dataset.runs >= 1);
  await page.getByLabel("Your name").fill("Ann");
  await page.getByLabel("Your name").press("Enter");
  await page.getByRole("button", { name: "Greet" }).click();
  await expect(page.getByTestId("st-alert-success")).toHaveText(/Hello Ann/);
});
```

Useful hooks in the page:

- `document.body.dataset.running` is `"1"` while a run is in progress; `dataset.runs` counts
  finished runs. Wait on them instead of sleeping (see `rerun()` in `tests/e2e/specs/helpers.js`).
- Elements carry `data-testid="st-<kind>"` (`st-dataframe`, `st-vega-lite`, `st-alert-success`,
  `st-chat-input`, `st-dialog`, …). Widget wrappers also have `data-label`.
- Charts and maps set `data-rendered="1"` when drawn.

Run everything (unit, e2e and doc snippets) with:

```sh
./run-tests.sh
```

Playwright uses the Chromium in `~/.cache/ms-playwright`, or `CHROMIUM_PATH`.
