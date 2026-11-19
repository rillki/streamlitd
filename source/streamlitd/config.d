/// Configuration: `.streamlitd/config.toml` (or `.streamlit/config.toml`), environment
/// variables and command-line flags. Precedence: CLI > `STREAMLITD_*` env > file > defaults.
module streamlitd.config;

import std.conv : to;
import std.path : buildPath, expandTilde;
import std.process : environment;
import std.string : toUpper;
import std.algorithm : canFind;
import vibe.data.json;

import streamlitd.secrets : deepMerge;
import streamlitd.theme;
import streamlitd.toml;

/// OpenAPI schema and Swagger UI for the app's API endpoints (`[api]`, see docs/api-endpoints.md).
struct ApiDocsOptions
{
	/// Serve the OpenAPI document and Swagger UI (`[api] docs`, `STREAMLITD_API_DOCS`, `--api-docs`). Off by default.
	bool docs = false;
	/// Path of the Swagger UI page, under the base path.
	string docsPath = "/docs";
	/// Path of the OpenAPI JSON document, under the base path.
	string specPath = "/openapi.json";
	/// `info.title` of the OpenAPI document.
	string title = "streamlitd API";
	/// `info.version` of the OpenAPI document.
	string version_ = "1.0.0";
}

/// A color scheme from `[theme.schemes.<name>]` (see `registerColorScheme`).
struct ColorSchemeConfig
{
	string name;
	string label;
	string base = "streamlit";
	ThemeTokens both, light, dark;
}

/// A design style from `[theme.designs.<name>]` (see `registerDesign`).
struct DesignConfig
{
	DesignStyle style;
	string cssPath;
}

/// A custom element's browser files from `[elements.<name>]` (see `registerElement`).
struct ElementConfig
{
	string name;
	string jsPath;
	string cssPath;
}

/// Server settings (see `serve`).
/// Where the header's rerun (⟳) and appearance (⚙) buttons go (`[ui]`).
struct UiOptions
{
	string rerunButton = "header";    /// "header", "menu" (one ⋮ menu in the header) or "hidden"
	string settingsButton = "header"; /// ditto, for the appearance panel
	bool rerunShortcut = true;        /// the R key reruns the app (also when the button is hidden)
}

/// Check a `[ui]` placement value ("header", "menu", "hidden").
string uiPlacement(string v, string what)
{
	if (v != "header" && v != "menu" && v != "hidden")
		throw new Exception(what ~ ` must be "header", "menu" or "hidden", not "` ~ v ~ `"`);
	return v;
}

/// A user-management command given on the command line.
struct UserCommand
{
	string kind;      /// "add", "set-password", "delete", "list", "reset-link", "set-roles"
	string username;
	string[] roles;   /// --roles admin,editor
	bool rolesGiven;
	string email;
	string name;
}

struct ServerOptions
{
	ushort port = 8501;
	string host = "0.0.0.0";
	size_t maxUploadMB = 200;
	bool quiet = false;
	/// Worker threads running app scripts: -1 = one per CPU core, 0 = run scripts as fibers
	/// on the event-loop thread (single-threaded mode).
	int scriptThreads = -1;
	/// Serve the app under a path prefix, e.g. "/myapp" (behind a reverse proxy).
	string baseUrlPath;
	/// Extra origins allowed to open the WebSocket / upload (e.g. "https://portal.example.com"; "*" = any).
	string[] allowedOrigins;
	/// Maximum concurrent sessions (0 = unlimited).
	size_t maxSessions = 0;
	/// Close sessions without client activity for this many seconds (0 = never).
	uint idleTimeoutSeconds = 0;
	/// Default design style, mode and overrides (CLI: `--theme`, `--theme-mode`, `--theme.<key>=<value>`).
	Theme theme;
	/// Let viewers change style/mode from the settings menu (CLI: `--no-theme-switch`).
	bool allowThemeSwitch = true;
	/// App-wide favicon: path to an image file (svg, png, ico, ...). Empty = streamlitd's icon.
	string favicon;
	/// Tile URL template for `st.map` (`[map] tileUrl`), e.g. an internal tile server for offline use.
	string mapTileUrl = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
	/// Attribution HTML shown on maps (`[map] attribution`).
	string mapAttribution = "&copy; OpenStreetMap contributors";
	/// Require login for the whole app (CLI `--auth-required`; same as `[auth] required = true`).
	bool authRequired;
	/// Raw `[auth]` table from the config file (see `streamlitd.auth`).
	Json auth;
	/// `[auth]` keys from `STREAMLITD_AUTH_*` environment variables; they win over config.toml and
	/// secrets.toml (e.g. `STREAMLITD_AUTH_USERS_FILE`, `STREAMLITD_AUTH_REGISTRATION`).
	Json authEnv;
	/// A user command from the command line (`--add-user`, `--list-users`, ...); empty `kind` = none.
	UserCommand userCommand;
	/// Behind a reverse proxy: take the client address from `X-Forwarded-For` (login throttling
	/// and logs), using the last entry, which the proxy appends. Only enable it when a proxy is
	/// always in front of the app (`[server] trustProxy`).
	bool trustProxy;
	/// Header controls (`[ui]`): where the rerun and appearance buttons go.
	UiOptions ui;
	/// OpenAPI / Swagger UI settings (`[api]`).
	ApiDocsOptions api;
	/// Color schemes, design styles and elements defined in config files; `serve` registers them.
	ColorSchemeConfig[] schemes;
	/// ditto
	DesignConfig[] designs;
	/// ditto
	ElementConfig[] elements;
}

/// Config files searched, lowest priority first.
string[] configSearchPaths()
{
	return [
		expandTilde("~/.streamlitd/config.toml"),
		buildPath(".streamlit", "config.toml"),
		buildPath(".streamlitd", "config.toml"),
	];
}

/// Load and merge all config files (or just `explicitPath` if given).
Json loadConfigFiles(string explicitPath = null)
{
	if (explicitPath.length)
		return readTomlFile(explicitPath);
	auto cfg = Json.emptyObject;
	foreach (p; configSearchPaths())
		cfg = deepMerge(cfg, readTomlFile(p));
	return cfg;
}

/// Apply a parsed config (`[server]`, `[theme]`, `[map]`, `[auth]`) to the options.
/// Unknown keys (e.g. Streamlit-only options such as `runOnSave` or a `[browser]` section)
/// are ignored and returned as warnings, so existing `.streamlit/config.toml` files work.
string[] applyConfig(ref ServerOptions o, Json cfg)
{
	string[] warnings;
	auto s = cfg["server"];
	if (s.type == Json.Type.object)
	{
		foreach (string k, v; s)
		{
			switch (k)
			{
				case "port": o.port = v.to!ushort; break;
				case "address": o.host = v.get!string; break;
				case "maxUploadSize": o.maxUploadMB = v.to!size_t; break;
				case "scriptThreads": o.scriptThreads = v.to!int; break;
				case "baseUrlPath": o.baseUrlPath = v.get!string; break;
				case "maxSessions": o.maxSessions = v.to!size_t; break;
				case "idleTimeout": o.idleTimeoutSeconds = v.to!uint; break;
				case "headless": o.quiet = v.get!bool; break;
				case "favicon": o.favicon = v.get!string; break;
				case "trustProxy": o.trustProxy = v.get!bool; break;
				case "allowedOrigins":
					o.allowedOrigins = null;
					foreach (e; v)
						o.allowedOrigins ~= e.get!string;
					break;
				default:
					warnings ~= "ignoring unsupported [server] option '" ~ k ~ "'";
			}
		}
	}
	auto t = cfg["theme"];
	if (t.type == Json.Type.object)
	{
		foreach (string k, v; t)
		{
			switch (k)
			{
				case "scheme":
				case "preset": o.theme.scheme = v.get!string; break; // `preset` = old name
				case "design": o.theme.design = v.get!string; break;
				case "mode": o.theme.mode = v.get!string; break;
				case "base": o.theme.mode = v.get!string; break; // Streamlit's light/dark base
				case "allowSwitch": o.allowThemeSwitch = v.get!bool; break;
				case "schemes":
					foreach (string name, def; v)
						upsert(o.schemes, parseSchemeConfig(name, def, warnings));
					break;
				case "designs":
					foreach (string name, def; v)
						upsert(o.designs, parseDesignConfig(name, def, warnings));
					break;
				case "chartColors":
					string[] cs;
					foreach (e; v)
						cs ~= e.get!string;
					o.theme.overrides.chartColors = cs;
					break;
				case "font":
				case "headingFont":
				case "codeFont":
					o.theme.overrides.set(k, streamlitFont(v.get!string));
					break;
				default:
					if (v.type == Json.Type.object || !o.theme.overrides.set(k, v.type == Json.Type.string ? v.get!string : v.toString))
						warnings ~= "ignoring unsupported [theme] option '" ~ k ~ "'";
			}
		}
	}
	auto m = cfg["map"];
	if (m.type == Json.Type.object)
	{
		if (m["tileUrl"].type == Json.Type.string)
			o.mapTileUrl = m["tileUrl"].get!string;
		if (m["attribution"].type == Json.Type.string)
			o.mapAttribution = m["attribution"].get!string;
	}
	if (cfg["auth"].type == Json.Type.object)
		o.auth = cfg["auth"];
	auto a = cfg["api"];
	if (a.type == Json.Type.object)
	{
		foreach (string k, v; a)
		{
			switch (k)
			{
				case "docs": o.api.docs = boolValue(v, "[api] docs"); break;
				case "docsPath": o.api.docsPath = routePath(v.get!string); break;
				case "specPath": o.api.specPath = routePath(v.get!string); break;
				case "title": o.api.title = v.get!string; break;
				case "version": o.api.version_ = v.type == Json.Type.string ? v.get!string : v.toString; break;
				default:
					warnings ~= "ignoring unsupported [api] option '" ~ k ~ "'";
			}
		}
		if (o.api.docsPath == o.api.specPath)
			throw new Exception("[api] docsPath and specPath must differ");
	}
	auto ui = cfg["ui"];
	if (ui.type == Json.Type.object)
		foreach (string k, v; ui)
			switch (k)
			{
				case "rerunButton": o.ui.rerunButton = uiPlacement(v.get!string, "[ui] rerunButton"); break;
				case "settingsButton": o.ui.settingsButton = uiPlacement(v.get!string, "[ui] settingsButton"); break;
				case "rerunShortcut": o.ui.rerunShortcut = boolValue(v, "[ui] rerunShortcut"); break;
				default: warnings ~= "ignoring unsupported [ui] option '" ~ k ~ "'";
			}
	auto els = cfg["elements"];
	if (els.type == Json.Type.object)
		foreach (string name, def; els)
		{
			ElementConfig e;
			e.name = name;
			if (def.type != Json.Type.object)
				throw new Exception("[elements." ~ name ~ "] must be a table with js and/or css");
			foreach (string k, v; def)
				switch (k)
				{
					case "js": e.jsPath = v.get!string; break;
					case "css": e.cssPath = v.get!string; break;
					default: warnings ~= "ignoring unsupported [elements." ~ name ~ "] option '" ~ k ~ "'";
				}
			upsert(o.elements, e);
		}
	foreach (string sec, _; cfg)
		if (!["server", "theme", "map", "auth", "api", "elements", "ui"].canFind(sec))
			warnings ~= "ignoring unsupported config section [" ~ sec ~ "]";
	return warnings;
}

/// Replace the entry with the same name (a later config file wins) or append.
private void upsert(T)(ref T[] list, T item)
{
	static if (is(T == DesignConfig))
		auto name = item.style.name;
	else
		auto name = item.name;
	foreach (ref x; list)
	{
		static if (is(T == DesignConfig))
			auto n = x.style.name;
		else
			auto n = x.name;
		if (n == name)
		{
			x = item;
			return;
		}
	}
	list ~= item;
}

/// Theme tokens from a config table (`[theme.schemes.x]`, `.light`, `.dark`); `skip` = other keys.
private void parseTokens(Json tbl, ref ThemeTokens t, string where, ref string[] warnings, const string[] skip = null)
{
	foreach (string k, v; tbl)
	{
		if (skip.canFind(k))
			continue;
		switch (k)
		{
			case "chartColors":
				t.chartColors = null;
				foreach (e; v)
					t.chartColors ~= e.get!string;
				break;
			case "font":
			case "headingFont":
			case "codeFont":
				t.set(k, streamlitFont(v.get!string));
				break;
			default:
				if (v.type == Json.Type.object || !t.set(k, v.type == Json.Type.string ? v.get!string : v.toString))
					warnings ~= "ignoring unsupported " ~ where ~ " option '" ~ k ~ "'";
		}
	}
}

private ColorSchemeConfig parseSchemeConfig(string name, Json def, ref string[] warnings)
{
	auto where = "[theme.schemes." ~ name ~ "]";
	if (def.type != Json.Type.object)
		throw new Exception(where ~ " must be a table");
	ColorSchemeConfig c;
	c.name = name;
	c.label = def["label"].opt!string(null);
	c.base = def["base"].opt!string("streamlit");
	parseTokens(def, c.both, where, warnings, ["label", "base", "light", "dark"]);
	if (def["light"].type == Json.Type.object)
		parseTokens(def["light"], c.light, "[theme.schemes." ~ name ~ ".light]", warnings);
	if (def["dark"].type == Json.Type.object)
		parseTokens(def["dark"], c.dark, "[theme.schemes." ~ name ~ ".dark]", warnings);
	return c;
}

private DesignConfig parseDesignConfig(string name, Json def, ref string[] warnings)
{
	auto where = "[theme.designs." ~ name ~ "]";
	if (def.type != Json.Type.object)
		throw new Exception(where ~ " must be a table");
	DesignConfig d;
	d.style.name = name;
	double num(Json v) { return v.type == Json.Type.int_ ? v.get!long : v.get!double; }
	foreach (string k, v; def)
		switch (k)
		{
			case "label": d.style.label = v.get!string; break;
			case "description": d.style.description = v.get!string; break;
			case "css": d.cssPath = v.get!string; break;
			case "font": d.style.font = streamlitFont(v.get!string); break;
			case "headingFont": d.style.headingFont = streamlitFont(v.get!string); break;
			case "codeFont": d.style.codeFont = streamlitFont(v.get!string); break;
			case "baseRadius": d.style.baseRadius = v.get!string; break;
			case "strokeWidth": d.style.strokeWidth = num(v); break;
			case "barRadius": d.style.barRadius = num(v); break;
			case "gridDash":
				foreach (e; v)
					d.style.gridDash ~= num(e);
				break;
			default:
				warnings ~= "ignoring unsupported " ~ where ~ " option '" ~ k ~ "'";
		}
	return d;
}

/// `true`/`false`, `1`/`0`, `yes`/`no`, `on`/`off`.
bool boolValue(Json v, string what)
{
	import std.string : toLower;
	if (v.type == Json.Type.bool_) return v.get!bool;
	if (v.type == Json.Type.int_) return v.get!long != 0;
	if (v.type == Json.Type.string)
		switch (v.get!string.toLower)
		{
			case "true": case "1": case "yes": case "on": return true;
			case "false": case "0": case "no": case "off": case "": return false;
			default: break;
		}
	throw new Exception(what ~ " must be true or false, not " ~ v.toString);
}

/// Normalize an `[api] docsPath` / `specPath`: leading `/`; not empty, not `/`, no `*` or `:` patterns.
package string routePath(string p)
{
	import std.algorithm : canFind;
	import std.string : strip;
	p = p.strip;
	if (p.length == 0 || p == "/")
		throw new Exception("[api] paths must not be empty or /");
	if (p.canFind('*') || p.canFind(':'))
		throw new Exception("[api] paths must be plain paths, not patterns: " ~ p);
	return p[0] == '/' ? p : "/" ~ p;
}

/// Map Streamlit's font keywords ("sans serif", "serif", "monospace") to font stacks;
/// anything else is used as a CSS font-family as is.
string streamlitFont(string v)
{
	switch (v)
	{
		case "sans serif": case "sans-serif": return fontSans;
		case "serif": return fontSerif;
		case "monospace": return fontMono;
		default: return v;
	}
}

/// Apply `STREAMLITD_SERVER_<KEY>` / `STREAMLITD_THEME_<KEY>` / `STREAMLITD_API_<KEY>` environment variables
/// (e.g. `STREAMLITD_SERVER_PORT=8080`, `STREAMLITD_THEME_PRESET=ocean`, `STREAMLITD_API_DOCS=true`).
void applyEnv(ref ServerOptions o, string[string] env)
{
	auto cfg = Json.emptyObject;
	cfg["server"] = Json.emptyObject;
	cfg["theme"] = Json.emptyObject;
	static immutable serverKeys = ["port", "address", "maxUploadSize", "scriptThreads", "baseUrlPath",
		"maxSessions", "idleTimeout", "headless", "favicon", "trustProxy"];
	static immutable themeKeys = ["scheme", "preset", "design", "mode", "base", "primaryColor", "backgroundColor",
		"secondaryBackgroundColor", "textColor", "font", "headingFont", "codeFont", "baseRadius"];
	foreach (k; serverKeys)
		if (auto v = ("STREAMLITD_SERVER_" ~ k.toUpper) in env)
			cfg["server"][k] = envValue(*v);
	if (auto v = "STREAMLITD_PORT" in env) // short alias
		cfg["server"]["port"] = envValue(*v);
	foreach (k; themeKeys)
		if (auto v = ("STREAMLITD_THEME_" ~ k.toUpper) in env)
			cfg["theme"][k] = *v;
	static immutable uiKeys = ["rerunButton", "settingsButton", "rerunShortcut"];
	foreach (k; uiKeys)
		if (auto v = ("STREAMLITD_UI_" ~ k.toUpper) in env)
		{
			if (cfg["ui"].type != Json.Type.object)
				cfg["ui"] = Json.emptyObject;
			cfg["ui"][k] = *v; // rerunShortcut: true/false, 1/0, yes/no, on/off
		}
	static immutable apiKeys = ["docs", "docsPath", "specPath", "title", "version"];
	foreach (k; apiKeys)
		if (auto v = ("STREAMLITD_API_" ~ k.toUpper) in env)
		{
			if (cfg["api"].type != Json.Type.object)
				cfg["api"] = Json.emptyObject;
			cfg["api"][k] = *v;
		}
	applyConfig(o, cfg);
	static immutable authKeys = ["required", "registration", "users_file", "cookie_secret", "password_min_length", "require_email",
		"signups_per_hour"];
	foreach (k; authKeys)
		if (auto v = ("STREAMLITD_AUTH_" ~ k.toUpper) in env)
		{
			if (o.authEnv.type != Json.Type.object)
				o.authEnv = Json.emptyObject;
			o.authEnv[k] = envValue(*v);
		}
}

private Json envValue(string v)
{
	if (v == "true") return Json(true);
	if (v == "false") return Json(false);
	try return Json(v.to!long); catch (Exception) {}
	return Json(v);
}

/// Normalize a base path: "" or "/prefix" (leading slash, no trailing slash).
string normalizeBasePath(string p)
{
	import std.string : strip;
	p = p.strip;
	while (p.length && p[$ - 1] == '/')
		p = p[0 .. $ - 1];
	if (p.length && p[0] != '/')
		p = "/" ~ p;
	return p;
}

unittest
{
	ServerOptions o;
	applyConfig(o, parseToml(`
[server]
port = 9000
baseUrlPath = "app"
allowedOrigins = ["https://a.example"]
scriptThreads = 2
[theme]
preset = "ocean"
base = "dark"
primaryColor = "#123456"
`));
	assert(o.port == 9000 && o.baseUrlPath == "app" && o.allowedOrigins == ["https://a.example"]);
	assert(o.scriptThreads == 2);
	assert(o.theme.scheme == "ocean" && o.theme.mode == "dark" && o.theme.overrides.primaryColor == "#123456");
	applyEnv(o, ["STREAMLITD_SERVER_PORT": "9100", "STREAMLITD_THEME_PRESET": "paper"]);
	assert(o.port == 9100 && o.theme.scheme == "paper");
	applyConfig(o, parseToml("[theme]\nscheme = \"forest\"\ndesign = \"terminal\"\n"));
	assert(o.theme.scheme == "forest" && o.theme.design == "terminal");
	applyEnv(o, ["STREAMLITD_THEME_DESIGN": "xp", "STREAMLITD_THEME_SCHEME": "ocean"]);
	assert(o.theme.design == "xp" && o.theme.scheme == "ocean");
	// Streamlit-only options are ignored with a warning, not fatal
	auto w = applyConfig(o, parseToml("[server]\nrunOnSave = true\nport = 9200\n[browser]\ngatherUsageStats = false\n[theme]\nfont = \"serif\"\n"));
	assert(w.length == 2 && o.port == 9200, w.to!string);
	assert(o.theme.overrides.font == fontSerif);
	// [api]: off by default; config, env (1/true/yes) and paths
	assert(!ServerOptions.init.api.docs);
	w = applyConfig(o, parseToml("[api]\ndocs = true\ndocsPath = \"swagger\"\ntitle = \"Todos\"\nversion = \"2.1\"\nfoo = 1\n"));
	assert(o.api.docs && o.api.docsPath == "/swagger" && o.api.specPath == "/openapi.json" && o.api.title == "Todos"
		&& o.api.version_ == "2.1" && w.length == 1, w.to!string);
	applyEnv(o, ["STREAMLITD_API_DOCS": "0"]);
	assert(!o.api.docs);
	applyEnv(o, ["STREAMLITD_API_DOCS": "yes", "STREAMLITD_API_SPECPATH": "/spec.json"]);
	assert(o.api.docs && o.api.specPath == "/spec.json");
	import std.exception : assertThrown;
	assertThrown(applyEnv(o, ["STREAMLITD_API_DOCS": "maybe"]));
	// [theme.schemes.*], [theme.designs.*], [elements.*]
	ServerOptions e;
	w = applyConfig(e, parseToml(`
[theme.schemes.acme]
label = "Acme"
primaryColor = "#0055aa"
font = "serif"
chartColors = ["#0055aa", "#ff8800"]
bogus = 1
[theme.schemes.acme.dark]
backgroundColor = "#0b1220"
[theme.designs.neon]
label = "Neon"
css = "neon.css"
font = "monospace"
strokeWidth = 3
gridDash = [2, 3.5]
[elements.rating]
js = "rating.js"
css = "rating.css"
`));
	assert(w.length == 1 && w[0].canFind("bogus"), w.to!string);
	assert(e.schemes.length == 1 && e.schemes[0].label == "Acme" && e.schemes[0].base == "streamlit");
	assert(e.schemes[0].both.primaryColor == "#0055aa" && e.schemes[0].both.font == fontSerif);
	assert(e.schemes[0].both.chartColors.length == 2 && e.schemes[0].dark.backgroundColor == "#0b1220");
	assert(e.designs.length == 1 && e.designs[0].cssPath == "neon.css" && e.designs[0].style.font == fontMono);
	assert(e.designs[0].style.strokeWidth == 3 && e.designs[0].style.gridDash == [2.0, 3.5]);
	assert(e.elements == [ElementConfig("rating", "rating.js", "rating.css")]);
	applyConfig(e, parseToml("[theme.schemes.acme]\nlabel = \"Acme 2\"\n")); // a later file replaces it
	assert(e.schemes.length == 1 && e.schemes[0].label == "Acme 2");
	assertThrown(applyConfig(o, parseToml("[api]\ndocsPath = \"/x\"\nspecPath = \"/x\"\n")));
	assert(normalizeBasePath("app/") == "/app");
	assert(normalizeBasePath("/") == "");
	assert(normalizeBasePath("") == "");
}
