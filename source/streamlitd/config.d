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

/// Server settings (see `serve`).
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
	/// OpenAPI / Swagger UI settings (`[api]`).
	ApiDocsOptions api;
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
	foreach (string sec, _; cfg)
		if (!["server", "theme", "map", "auth", "api"].canFind(sec))
			warnings ~= "ignoring unsupported config section [" ~ sec ~ "]";
	return warnings;
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
		"maxSessions", "idleTimeout", "headless", "favicon"];
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
	static immutable apiKeys = ["docs", "docsPath", "specPath", "title", "version"];
	foreach (k; apiKeys)
		if (auto v = ("STREAMLITD_API_" ~ k.toUpper) in env)
		{
			if (cfg["api"].type != Json.Type.object)
				cfg["api"] = Json.emptyObject;
			cfg["api"][k] = *v;
		}
	applyConfig(o, cfg);
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
	assertThrown(applyConfig(o, parseToml("[api]\ndocsPath = \"/x\"\nspecPath = \"/x\"\n")));
	assert(normalizeBasePath("app/") == "/app");
	assert(normalizeBasePath("/") == "");
	assert(normalizeBasePath("") == "");
}
