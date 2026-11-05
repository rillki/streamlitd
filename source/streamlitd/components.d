/// Custom components: static HTML/iframes and bidirectional components that speak
/// Streamlit's component postMessage protocol (`streamlit:componentReady`,
/// `streamlit:render`, `streamlit:setComponentValue`, `streamlit:setFrameHeight`), so
/// existing Streamlit component frontends with JSON arguments work unchanged.
module streamlitd.components;

import core.sync.mutex : Mutex;
import vibe.data.json;

import streamlitd.delta : St;
import streamlitd.errors : StreamlitAPIException;
import streamlitd.util;

/// Where a declared component's frontend comes from.
struct ComponentSource
{
	string name;
	string dir;   /// directory with index.html (served at `_components/<name>/`)
	string html;  /// inline HTML (served as `_components/<name>/index.html`)
	string url;   /// external dev server URL
}

private __gshared ComponentSource[string] g_components;
private __gshared Mutex g_lock;
shared static this() { g_lock = new Mutex; }

/// Look up a declared component (used by the server).
ComponentSource* findComponent(string name)
{
	synchronized (g_lock)
		return name in g_components;
}

/// A declared bidirectional component; call it like a widget.
struct Component
{
	string name;

	/// Render the component and return its current value (`default_` until it sends one).
	Json opCall(St st, Json args = Json.emptyObject, string key = null, Json default_ = Json(null), int height = 0)
	{
		return st.customComponent(name, args, key, default_, height);
	}
}

/// Declare a component (`components.declare_component`). Give exactly one of `path`
/// (directory containing index.html), `html` (inline page) or `url` (dev server).
Component declareComponent(string name, string path = null, string html = null, string url = null)
{
	import std.file : exists, isDir;
	import std.path : absolutePath, buildPath;
	int given = (path.length > 0) + (html.length > 0) + (url.length > 0);
	if (given != 1)
		throw new StreamlitAPIException("declareComponent(\"" ~ name ~ "\") needs exactly one of path, html or url");
	foreach (c; name)
		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'))
			throw new StreamlitAPIException("component name may only contain letters, digits, '_' and '-'");
	ComponentSource src;
	src.name = name;
	if (path.length)
	{
		auto abs = absolutePath(path);
		if (!exists(buildPath(abs, "index.html")))
			throw new StreamlitAPIException("component \"" ~ name ~ "\": " ~ buildPath(abs, "index.html") ~ " not found");
		src.dir = abs;
	}
	src.html = html;
	src.url = url;
	synchronized (g_lock)
		g_components[name] = src;
	Component c; // not Component(name): that syntax would call opCall
	c.name = name;
	return c;
}

/// `st.components` API (static HTML and iframes).
struct ComponentsApi
{
	private St st;

	/// `components.html`: render HTML in a sandboxed iframe.
	void html(string body_, int height = 150, bool scrolling = false)
	{
		st.emitComponent(jo("kind", "component_html", "html", body_, "height", height, "scrolling", scrolling));
	}

	/// `components.iframe`: embed a URL.
	void iframe(string src, int height = 150, bool scrolling = false, int width = 0)
	{
		st.emitComponent(jo("kind", "iframe", "src", src, "height", height, "scrolling", scrolling, "width", width));
	}
}

/// Component elements mixed into `St`.
mixin template ComponentElements()
{
	/// `st.components.html(...)`, `st.components.iframe(...)`
	@property ComponentsApi components() { return ComponentsApi(this); }

	/// `st.iframe(url)`
	void iframe(string src, int height = 150, bool scrolling = false, int width = 0)
	{
		components.iframe(src, height, scrolling, width);
	}

	package void emitComponent(Json el) { emit(el); }

	/// Render a declared component (prefer `Component.opCall`).
	Json customComponent(string name, Json args, string key, Json default_, int height)
	{
		auto src = findComponent(name);
		if (src is null)
			throw new StreamlitAPIException("component \"" ~ name ~ "\" was not declared");
		auto url = src.url.length ? src.url : "_components/" ~ name ~ "/index.html";
		auto id = widgetId("component", key, name, args.toString);
		auto p = jo("name", name, "src", url, "args", args, "height", height);
		return widget!Json("component", id, key, default_, (Json v) => v, (Json j) => j, null, p);
	}
}
