/// App-defined native elements and widgets (`registerElement`, `st.customElement`,
/// `st.customWidget!T`), and the files that carry the app's extensions to the browser: one
/// stylesheet for designs and elements, one script per element. See docs/extending.md.
///
/// Unlike iframe components (`declareComponent`), custom elements render directly in the page:
/// they follow the color scheme, mode and design style, and their values go through the same path
/// as built-in widgets (keys, session state, callbacks, forms, fragments, server-side decoding).
/// Their JavaScript runs in the app's page, so only register code you trust.
module streamlitd.extensions;

import vibe.data.json;

import streamlitd.errors : StreamlitAPIException;
import streamlitd.theme : g_extLock, checkExtensionName, checkNotFrozen, customDesignCss;

/// A registered custom element: its browser code and styles.
struct CustomElement
{
	string name;
	string js;   /// calls `StreamlitD.registerElement(name, {render(box, el, api) {...}})`
	string css;
}

private __gshared CustomElement[] g_elements;

/// Register a custom element or widget: `js` (or the file `jsPath`) renders it in the browser,
/// `css` (or `cssPath`) styles it. Use it in the app with `st.customElement(name, props)` or
/// `st.customWidget!T(name, label, default_, ...)`. Call it before the server starts, e.g. in
/// `shared static this()`; `[elements.<name>]` in config.toml does the same with file paths.
void registerElement(string name, string js = null, string css = null, string jsPath = null, string cssPath = null)
{
	import std.file : readText;
	checkNotFrozen("registerElement");
	checkExtensionName("element", name);
	auto where = `element "` ~ name ~ `"`;
	if ((js.length && jsPath.length) || (css.length && cssPath.length))
		throw new StreamlitAPIException(where ~ ": give the code or the file path, not both");
	string load(string path)
	{
		try
			return readText(path);
		catch (Exception e)
			throw new StreamlitAPIException(where ~ ": cannot read " ~ path ~ ": " ~ e.msg);
	}
	if (jsPath.length)
		js = load(jsPath);
	if (cssPath.length)
		css = load(cssPath);
	if (!js.length)
		throw new StreamlitAPIException(where ~ " needs JavaScript (js or jsPath) that registers its renderer");
	synchronized (g_extLock)
	{
		foreach (e; g_elements)
			if (e.name == name)
				throw new StreamlitAPIException(where ~ " is already registered");
		g_elements ~= CustomElement(name, js, css);
	}
}

/// True if `name` was registered with `registerElement`.
bool isElementRegistered(string name)
{
	synchronized (g_extLock)
		foreach (e; g_elements)
			if (e.name == name)
				return true;
	return false;
}

/// Names of all registered custom elements.
string[] elementNames()
{
	string[] r;
	synchronized (g_extLock)
		foreach (e; g_elements)
			r ~= e.name;
	return r;
}

/// Forget all registered elements (tests).
package void resetElements()
{
	synchronized (g_extLock)
		g_elements = null;
}

/// One element's script, served at `_stcore/ext/<name>.js`.
struct ElementScript
{
	string name;
	string js;
	string hash; /// for cache-busting URLs
}

/// The extension files: one stylesheet (`_stcore/ext.css`, empty = none) and one script per element.
/// Separate scripts keep a syntax error in one element from stopping the others.
struct ExtensionAssets
{
	string css;
	string cssHash; /// for cache-busting URLs
	ElementScript[] scripts;

	/// The script of element `name`, or null.
	const(ElementScript)* script(string name) const
	{
		foreach (ref s; scripts)
			if (s.name == name)
				return &s;
		return null;
	}
}

/// Build the extension assets from the registered designs and elements.
package ExtensionAssets buildExtensionAssets()
{
	import std.digest : toHexString, LetterCase;
	import std.digest.sha : sha1Of;
	string hash(string s) { return s.length ? toHexString!(LetterCase.lower)(sha1Of(s))[0 .. 12].idup : null; }
	ExtensionAssets a;
	a.css = customDesignCss();
	synchronized (g_extLock)
		foreach (e; g_elements)
		{
			if (e.css.length)
				a.css ~= "/* element: " ~ e.name ~ " */\n" ~ e.css ~ "\n";
			// a runtime error is reported with the element's name (a syntax error stays in this file)
			auto js = "/* streamlitd custom element: " ~ e.name ~ " */\n(function () {\ntry {\n" ~ e.js ~
				"\n} catch (e) { console.error(\"streamlitd: custom element \\\"" ~ e.name ~ "\\\":\", e); }\n})();\n";
			a.scripts ~= ElementScript(e.name, js, hash(js));
		}
	a.cssHash = hash(a.css);
	return a;
}

/// `St` methods for custom elements (mixed into `St`; see `streamlitd.delta`).
mixin template CustomElements()
{
	/// Render a registered custom element that shows something but has no value.
	/// `props` reaches its renderer as `el.props`.
	void customElement(string name, Json props = Json.emptyObject)
	{
		if (!isElementRegistered(name))
			throw new StreamlitAPIException(`custom element "` ~ name ~ `" was not registered (registerElement or [elements.` ~ name ~ `])`);
		emit(jo("kind", "custom", "element", name, "props", props.type == Json.Type.object ? props : Json.emptyObject));
	}

	/// Render a registered custom widget and return its value: `default_` until the browser sends
	/// one with `api.setValue(v)`. The value is decoded into `T` on the server; anything that does
	/// not decode gives `default_`. Works with `key`, `st.session`, `onChange`, forms and fragments.
	/// `trigger: true` makes a button-like widget: `api.trigger(v)` returns `v` for that one run only.
	/// Always give `T` explicitly: `st.customWidget!int("rating", "Stars", 3, key: "r")`.
	T customWidget(T)(string name, string label, T default_, Json props = Json.emptyObject, string key = null,
		void delegate() onChange = null, bool disabled = false, string help = null,
		string labelVisibility = "visible", bool trigger = false)
	{
		if (!isElementRegistered(name))
			throw new StreamlitAPIException(`custom widget "` ~ name ~ `" was not registered (registerElement or [elements.` ~ name ~ `])`);
		if (props.type != Json.Type.object)
			props = Json.emptyObject;
		auto id = widgetId("custom", key, name, label, props.toString);
		auto p = jo("element", name, "label", label, "props", props, "disabled", disabled,
			"labelVisibility", labelVisibility);
		if (help.length)
			p["help"] = help;
		return widget!T("custom", id, key, default_, (T v) => serializeToJson(v), (Json j) => deserializeJson!T(j),
			onChange, p, trigger);
	}
}

unittest
{
	import std.algorithm : canFind;
	import std.exception : assertThrown;
	import std.file : write, remove, tempDir;
	import std.path : buildPath;
	import streamlitd.theme : resetThemeExtensions;
	resetThemeExtensions();
	resetElements();
	scope (exit) { resetThemeExtensions(); resetElements(); }

	assert(buildExtensionAssets() == ExtensionAssets.init); // nothing registered: nothing to load
	registerElement("badge", js: `StreamlitD.registerElement("badge", {render(box, el) {}});`, css: ".b{}");
	auto f = buildPath(tempDir, "streamlitd-ext-test.js");
	write(f, `StreamlitD.registerElement("rating", {render(box, el, api) {}});`);
	scope (exit) remove(f);
	registerElement("rating", jsPath: f);
	assert(isElementRegistered("rating") && elementNames() == ["badge", "rating"]);
	assertThrown!StreamlitAPIException(registerElement("badge", js: "x"));           // taken
	assertThrown!StreamlitAPIException(registerElement("nojs"));
	assertThrown!StreamlitAPIException(registerElement("x", jsPath: "/no/such/file.js"));
	assertThrown!StreamlitAPIException(registerElement("Bad!", js: "x"));
	auto a = buildExtensionAssets();
	assert(a.scripts.length == 2 && a.script("rating").js.canFind(`registerElement("rating"`)
		&& a.script("rating").js.canFind("catch (e)") && !a.script("rating").js.canFind(`"badge"`));
	assert(a.script("badge").hash.length == 12 && a.script("nope") is null);
	assert(a.css.canFind(".b{}") && a.cssHash.length == 12);
}
