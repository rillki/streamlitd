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
	/// Tile URL template for `st.map` (`[map] tileUrl`), e.g. an internal tile server for offline use.
	string mapTileUrl = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
	/// Attribution HTML shown on maps (`[map] attribution`).
	string mapAttribution = "&copy; OpenStreetMap contributors";
	/// Require login for the whole app (CLI `--auth-required`; same as `[auth] required = true`).
	bool authRequired;
	/// Raw `[auth]` table from the config file (see `streamlitd.auth`).
	Json auth;
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
	foreach (string sec, _; cfg)
		if (!["server", "theme", "map", "auth"].canFind(sec))
			warnings ~= "ignoring unsupported config section [" ~ sec ~ "]";
	return warnings;
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

/// Apply `STREAMLITD_SERVER_<KEY>` / `STREAMLITD_THEME_<KEY>` environment variables
/// (e.g. `STREAMLITD_SERVER_PORT=8080`, `STREAMLITD_THEME_PRESET=ocean`).
void applyEnv(ref ServerOptions o, string[string] env)
{
	auto cfg = Json.emptyObject;
	cfg["server"] = Json.emptyObject;
	cfg["theme"] = Json.emptyObject;
	static immutable serverKeys = ["port", "address", "maxUploadSize", "scriptThreads", "baseUrlPath",
		"maxSessions", "idleTimeout", "headless"];
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
	assert(normalizeBasePath("app/") == "/app");
	assert(normalizeBasePath("/") == "");
	assert(normalizeBasePath("") == "");
}
