/// Theming: **design styles** (the shape of the UI: fonts, borders, shadows, chrome),
/// **color schemes** (palettes) and **mode** (light/dark), plus Streamlit-style token overrides.
///
/// Streamlit itself only ships Light/Dark plus `[theme]` overrides in `config.toml`.
/// streamlitd keeps that model (field names follow Streamlit's config keys) and adds
/// named color schemes (each with a light and a dark variant) and design styles that
/// work with every scheme in both modes.
module streamlitd.theme;

import std.algorithm : canFind, map;
import std.array : array, join;
import vibe.data.json;

import streamlitd.util;

/// Theme values. Every field is optional; `null` means "inherit from the preset".
struct ThemeTokens
{
	string primaryColor;
	string primaryTextColor;        /// text on primary-colored buttons/chips
	string backgroundColor;
	string secondaryBackgroundColor;
	string textColor;
	string linkColor;
	string borderColor;
	string sidebarBackgroundColor;
	string widgetBackgroundColor;
	string widgetBorderColor;       /// set for "outlined" inputs
	string codeBackgroundColor;
	string font;
	string headingFont;
	string codeFont;
	string baseRadius;              /// CSS length, e.g. "0.5rem"
	string[] chartColors;

	/// Copy with every non-null field of `o` applied on top.
	ThemeTokens merged(const ThemeTokens o) const
	{
		ThemeTokens r = cast(ThemeTokens) this;
		static foreach (name; __traits(allMembers, ThemeTokens))
		{
			static if (is(typeof(__traits(getMember, ThemeTokens, name)) == string))
			{
				if (__traits(getMember, o, name) !is null)
					__traits(getMember, r, name) = __traits(getMember, o, name);
			}
			else static if (is(typeof(__traits(getMember, ThemeTokens, name)) == string[]))
			{
				if (__traits(getMember, o, name).length)
					__traits(getMember, r, name) = __traits(getMember, o, name).dup;
			}
		}
		return r;
	}

	/// Set one field by its config name (used for `--theme.<key>=<value>`). Returns false if unknown.
	bool set(string key, string value)
	{
		static foreach (name; __traits(allMembers, ThemeTokens))
		{
			static if (is(typeof(__traits(getMember, ThemeTokens, name)) == string))
			{
				if (key == name)
				{
					__traits(getMember, this, name) = value;
					return true;
				}
			}
		}
		if (key == "chartColors")
		{
			import std.array : split;
			import std.string : strip;
			chartColors = value.split(",").map!(s => s.strip).array;
			return true;
		}
		return false;
	}

	/// Only the fields that are set.
	Json toJson() const
	{
		auto o = Json.emptyObject;
		static foreach (name; __traits(allMembers, ThemeTokens))
		{
			static if (is(typeof(__traits(getMember, ThemeTokens, name)) == string))
			{
				if (__traits(getMember, this, name) !is null)
					o[name] = __traits(getMember, this, name);
			}
		}
		if (chartColors.length)
			o["chartColors"] = toJ(chartColors);
		return o;
	}
}

/// The theme an app asks for: a color scheme, a mode, a design style and optional overrides.
struct Theme
{
	string scheme = "streamlit"; /// color scheme (see `colorSchemeNames`)
	string mode = "auto";        /// "auto" (follow the OS), "light" or "dark"
	string design = "streamlit"; /// design style (see `designNames`)
	ThemeTokens overrides;

	/// Deprecated alias of `scheme` (the color schemes used to be called presets).
	@property string preset() const { return scheme; }
	/// ditto
	@property void preset(string v) { scheme = v; }
}

/// A design style: how the UI is shaped. Colors always come from the color scheme.
struct DesignStyle
{
	string name;
	string label;
	string description;
	/// Tokens the design forces (null = keep the scheme's): fonts and corner radius.
	string font, headingFont, codeFont, baseRadius;
	/// Chart tweaks for Vega-Lite/Plotly: line stroke width, bar corner radius, grid dash pattern.
	double strokeWidth = 2;
	double barRadius = 0;
	double[] gridDash;
}

enum fontTerminal = `"JetBrains Mono", "Cascadia Mono", "Fira Code", "Source Code Pro", Menlo, Consolas, "Liberation Mono", monospace`;
enum fontRetro = `"Press Start 2P", "VT323", "Courier New", Courier, "Liberation Mono", monospace`;
enum fontWin95 = `Tahoma, "MS Sans Serif", "Microsoft Sans Serif", Geneva, Verdana, "DejaVu Sans", sans-serif`;
enum fontXp = `Tahoma, "Segoe UI", Verdana, "DejaVu Sans", sans-serif`;
enum fontMaterial = `Roboto, "Segoe UI", "Helvetica Neue", Arial, system-ui, sans-serif`;

/// All design styles, in menu order. The first one is the default.
DesignStyle[] designStyles()
{
	static DesignStyle[] cache;
	if (cache.length)
		return cache;
	DesignStyle d(string name, string label, string description, string font = null, string radius = null,
		double stroke = 2, double barRadius = 0, double[] dash = null, string heading = null, string code = null)
	{
		DesignStyle s;
		s.name = name;
		s.label = label;
		s.description = description;
		s.font = font;
		s.headingFont = heading !is null ? heading : font;
		s.codeFont = code !is null ? code : (font is null ? null : fontMono);
		s.baseRadius = radius;
		s.strokeWidth = stroke;
		s.barRadius = barRadius;
		s.gridDash = dash;
		return s;
	}
	cache = [
		d("streamlit", "Streamlit", "The default Streamlit look"),
		d("terminal", "Terminal", "Monospace text, [ bracket ] buttons, dashed borders, phosphor glow in dark mode",
			fontTerminal, "0", 1.5, 0, [2.0, 3.0], fontTerminal, fontTerminal),
		d("retro", "Retro", "8-bit look: chunky borders, hard offset shadows, uppercase pixel type",
			fontRetro, "0", 3, 0, null, fontRetro, fontRetro),
		d("win95", "Classic (Win95)", "Gray 3D bevels, title bars and sunken inputs", fontWin95, "0", 1.5, 0),
		d("xp", "XP (Luna)", "Glossy rounded title bars, gradient buttons, task-pane sidebar", fontXp, "3px", 2, 2),
		d("brutalist", "Brutalist", "Thick borders, hard shadows, bold uppercase headings", null, "0", 3, 0),
		d("material", "Material", "Pill buttons, filled inputs, elevated cards", fontMaterial, "12px", 2.5, 4),
		d("glass", "Glass", "Translucent blurred panels over a soft gradient backdrop", null, "16px", 2.5, 6),
	];
	return cache;
}

/// Names of all design styles.
string[] designNames() { return designStyles().map!(d => d.name).array; }

/// Look up a design style; returns null if unknown.
const(DesignStyle)* findDesign(string name)
{
	foreach (ref d; designStyles())
		if (d.name == name)
			return &d;
	return null;
}

/// All design styles as JSON (sent to the browser once per session).
Json designsJson()
{
	auto a = Json.emptyArray;
	foreach (d; designStyles())
	{
		auto forced = Json.emptyObject;
		if (d.font !is null) forced["font"] = d.font;
		if (d.headingFont !is null) forced["headingFont"] = d.headingFont;
		if (d.codeFont !is null) forced["codeFont"] = d.codeFont;
		if (d.baseRadius !is null) forced["baseRadius"] = d.baseRadius;
		a ~= jo("name", d.name, "label", d.label, "description", d.description, "tokens", forced,
			"chart", jo("strokeWidth", d.strokeWidth, "barRadius", d.barRadius, "gridDash", d.gridDash));
	}
	return a;
}

/// A named color scheme (palette), with light and dark variants.
struct ThemePreset
{
	string name;
	string label;
	ThemeTokens light;
	ThemeTokens dark;
}

enum fontSans = `"Source Sans Pro", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`;
enum fontSerif = `Georgia, "Iowan Old Style", "Palatino Linotype", "Book Antiqua", "Times New Roman", serif`;
enum fontMono = `"Source Code Pro", SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace`;
enum fontRounded = `"Nunito", "Segoe UI Rounded", "SF Pro Rounded", "Segoe UI", system-ui, sans-serif`;

private ThemeTokens tk(string primary, string bg, string bg2, string text, string sidebar, string widget,
	string code, string[] chart, string widgetBorder = null, string onPrimary = "#ffffff",
	string link = null, string font = fontSans, string heading = null, string radius = "0.5rem")
{
	ThemeTokens t;
	t.primaryColor = primary;
	t.primaryTextColor = onPrimary;
	t.backgroundColor = bg;
	t.secondaryBackgroundColor = bg2;
	t.textColor = text;
	t.sidebarBackgroundColor = sidebar;
	t.widgetBackgroundColor = widget;
	t.widgetBorderColor = widgetBorder;
	t.codeBackgroundColor = code;
	t.linkColor = link is null ? primary : link;
	t.font = font;
	t.headingFont = heading is null ? font : heading;
	t.codeFont = fontMono;
	t.baseRadius = radius;
	t.chartColors = chart;
	return t;
}

/// All presets, in menu order. The first one is the default.
ThemePreset[] themePresets()
{
	static ThemePreset[] cache;
	if (cache.length)
		return cache;
	cache = [
		ThemePreset("streamlit", "Streamlit",
			tk("#ff4b4b", "#ffffff", "#f0f2f6", "#31333f", "#f0f2f6", "#f0f2f6", "#f0f2f6",
				["#0068c9", "#83c9ff", "#ff2b2b", "#ffabab", "#29b09d", "#7defa1", "#ff8700", "#ffd16a", "#6d3fc0", "#d5dae5"],
				null, "#ffffff", "#0068c9"),
			tk("#ff4b4b", "#0e1117", "#262730", "#fafafa", "#262730", "#262730", "#1a1c24",
				["#83c9ff", "#0068c9", "#ffabab", "#ff2b2b", "#7defa1", "#29b09d", "#ffd16a", "#ff8700", "#9a7ce0", "#d5dae5"],
				null, "#ffffff", "#58a6ff")),
		ThemePreset("minimal", "Minimal",
			tk("#111111", "#ffffff", "#f5f5f5", "#111111", "#fafafa", "#ffffff", "#f4f4f4",
				["#111111", "#2f6fed", "#777777", "#bbbbbb", "#444444", "#93b4f6", "#999999", "#dddddd", "#222222", "#5c5c5c"],
				"#d4d4d4", "#ffffff", "#2f6fed", fontSans, null, "0.25rem"),
			tk("#f5f5f5", "#0a0a0a", "#171717", "#ededed", "#111111", "#0a0a0a", "#171717",
				["#ededed", "#5b8cff", "#a3a3a3", "#525252", "#d4d4d4", "#a9c1ff", "#737373", "#404040", "#fafafa", "#8a8a8a"],
				"#3a3a3a", "#0a0a0a", "#7aa2ff", fontSans, null, "0.25rem")),
		ThemePreset("ocean", "Ocean",
			tk("#0068c9", "#ffffff", "#eef4fb", "#0f2a43", "#e3eef9", "#eef4fb", "#eef4fb",
				["#0068c9", "#00a3e0", "#5ac8fa", "#0b3d91", "#2ec4b6", "#83c9ff", "#4361ee", "#90e0ef", "#023e8a", "#48cae4"],
				null, "#ffffff", null, fontSans, null, "0.75rem"),
			tk("#4da3ff", "#0b1724", "#13263b", "#e6f0fa", "#0f1f31", "#13263b", "#0f1f31",
				["#4da3ff", "#5ac8fa", "#2ec4b6", "#90e0ef", "#4361ee", "#83c9ff", "#00a3e0", "#caf0f8", "#7b9cff", "#48cae4"],
				null, "#04121f", null, fontSans, null, "0.75rem")),
		ThemePreset("forest", "Forest",
			tk("#2e7d32", "#fbfaf5", "#eef0e6", "#1f2a1f", "#e8ecdf", "#eef0e6", "#eef0e6",
				["#2e7d32", "#81c784", "#a1887f", "#ffb300", "#558b2f", "#c5e1a5", "#6d4c41", "#26a69a", "#c0ca33", "#8d6e63"]),
			tk("#66bb6a", "#121a13", "#1d2a1e", "#e8efe4", "#172118", "#1d2a1e", "#172118",
				["#66bb6a", "#a5d6a7", "#bcaaa4", "#ffca28", "#9ccc65", "#4db6ac", "#d7ccc8", "#dce775", "#81c784", "#a1887f"],
				null, "#0d150e")),
		ThemePreset("sunset", "Sunset",
			tk("#f76707", "#fffaf5", "#fff0e3", "#3b2a2a", "#ffe8d6", "#fff0e3", "#fff0e3",
				["#f76707", "#ae3ec9", "#f03e3e", "#fab005", "#7048e8", "#e64980", "#ff922b", "#cc5de8", "#fcc419", "#9775fa"],
				null, "#ffffff", "#c2410c", fontRounded, null, "1rem"),
			tk("#ff922b", "#1a1020", "#2a1a30", "#fbefe6", "#22142a", "#2a1a30", "#22142a",
				["#ff922b", "#da77f2", "#ff6b6b", "#ffd43b", "#9775fa", "#f783ac", "#ffa94d", "#e599f7", "#ffe066", "#b197fc"],
				null, "#1a1020", "#ffa94d", fontRounded, null, "1rem")),
		ThemePreset("finance", "Finance",
			tk("#00a86b", "#f7f9fc", "#e6ecf4", "#0b1f3a", "#e6ecf4", "#ffffff", "#e6ecf4",
				["#0b3d91", "#00a86b", "#f5a623", "#d0021b", "#4a90e2", "#7ed321", "#9013fe", "#50e3c2", "#8b572a", "#b8e986"],
				"#c9d3e0", "#ffffff", "#0b5cad", fontSans, null, "0.375rem"),
			tk("#00c27c", "#0a1628", "#12233d", "#e6edf7", "#0d1b30", "#12233d", "#0d1b30",
				["#4a90e2", "#00c27c", "#f5a623", "#ff5a5f", "#50e3c2", "#b8e986", "#bd10e0", "#7ed321", "#f8e71c", "#9b9b9b"],
				"#22395c", "#04140c", "#6fb1ff", fontSans, null, "0.375rem")),
		ThemePreset("solarized", "Solarized",
			tk("#268bd2", "#fdf6e3", "#eee8d5", "#586e75", "#eee8d5", "#eee8d5", "#eee8d5",
				["#268bd2", "#2aa198", "#859900", "#b58900", "#cb4b16", "#dc322f", "#d33682", "#6c71c4", "#93a1a1", "#657b83"],
				null, "#fdf6e3", null, fontSans, fontMono, "0.25rem"),
			tk("#268bd2", "#002b36", "#073642", "#93a1a1", "#073642", "#073642", "#073642",
				["#268bd2", "#2aa198", "#859900", "#b58900", "#cb4b16", "#dc322f", "#d33682", "#6c71c4", "#93a1a1", "#839496"],
				null, "#fdf6e3", null, fontSans, fontMono, "0.25rem")),
		ThemePreset("paper", "Paper",
			tk("#b23a48", "#fffdf8", "#f3efe6", "#2b2b2b", "#f3efe6", "#ffffff", "#f3efe6",
				["#b23a48", "#3d5a80", "#e09f3e", "#335c67", "#9e2a2b", "#81b29a", "#540b0e", "#98c1d9", "#c9a227", "#6d6875"],
				"#d8d2c4", "#ffffff", null, fontSerif, fontSerif, "0.125rem"),
			tk("#e07a5f", "#1c1a17", "#2a2723", "#ece6da", "#24211d", "#1c1a17", "#2a2723",
				["#e07a5f", "#98c1d9", "#f2cc8f", "#81b29a", "#e5989b", "#3d5a80", "#ffb4a2", "#b5838d", "#c9a227", "#a8dadc"],
				"#4a453d", "#1c1a17", null, fontSerif, fontSerif, "0.125rem")),
	];
	return cache;
}

/// Names of all color schemes.
string[] colorSchemeNames() { return themePresets().map!(p => p.name).array; }

/// Deprecated alias of `colorSchemeNames`.
string[] themePresetNames() { return colorSchemeNames(); }

/// Look up a preset; returns null if unknown.
const(ThemePreset)* findPreset(string name)
{
	foreach (ref p; themePresets())
		if (p.name == name)
			return &p;
	return null;
}

/// Validate a theme; throws on unknown preset/mode.
void validateTheme(const Theme t)
{
	import streamlitd.errors : StreamlitAPIException;
	if (findPreset(t.scheme) is null)
		throw new StreamlitAPIException(`Unknown color scheme "` ~ t.scheme ~ `". Available: ` ~
			colorSchemeNames().join(", "));
	if (findDesign(t.design) is null)
		throw new StreamlitAPIException(`Unknown design style "` ~ t.design ~ `". Available: ` ~
			designNames().join(", "));
	if (!["auto", "light", "dark"].canFind(t.mode))
		throw new StreamlitAPIException(`Theme mode must be "auto", "light" or "dark", not "` ~ t.mode ~ `"`);
}

/// All presets as JSON (sent to the browser once per session).
Json presetsJson()
{
	auto a = Json.emptyArray;
	foreach (p; themePresets())
		a ~= jo("name", p.name, "label", p.label, "light", p.light.toJson(), "dark", p.dark.toJson());
	return a;
}

/// A theme as JSON.
Json themeJson(const Theme t, bool allowSwitch)
{
	return jo("scheme", t.scheme, "design", t.design, "mode", t.mode, "overrides", t.overrides.toJson(),
		"allowSwitch", allowSwitch);
}

unittest
{
	import std.regex : matchFirst, regex;
	auto hex = regex(`^#[0-9a-fA-F]{6}$`);
	assert(themePresets().length == 8);
	foreach (p; themePresets())
		foreach (t; [p.light, p.dark])
		{
			foreach (c; [t.primaryColor, t.primaryTextColor, t.backgroundColor, t.secondaryBackgroundColor,
				t.textColor, t.linkColor, t.sidebarBackgroundColor, t.widgetBackgroundColor, t.codeBackgroundColor])
				assert(!matchFirst(c, hex).empty, p.name ~ ": bad color " ~ c);
			if (t.widgetBorderColor !is null)
				assert(!matchFirst(t.widgetBorderColor, hex).empty, p.name);
			assert(t.chartColors.length == 10, p.name);
			foreach (c; t.chartColors)
				assert(!matchFirst(c, hex).empty, p.name ~ ": bad chart color " ~ c);
			assert(t.font.length && t.headingFont.length && t.codeFont.length && t.baseRadius.length, p.name);
		}
	assert(findPreset("ocean") !is null && findPreset("nope") is null);

	ThemeTokens o;
	assert(o.set("primaryColor", "#123456"));
	assert(o.set("chartColors", "#000000, #ffffff"));
	assert(!o.set("bogus", "x"));
	auto m = findPreset("ocean").light.merged(o);
	assert(m.primaryColor == "#123456" && m.backgroundColor == "#ffffff" && m.chartColors == ["#000000", "#ffffff"]);
	assert(o.toJson()["primaryColor"].get!string == "#123456");
	assert(o.toJson()["backgroundColor"].type == Json.Type.undefined);

	import std.exception : assertThrown;
	assertThrown(validateTheme(Theme("nope")));
	assertThrown(validateTheme(Theme("ocean", "dark", "no-such-design")));
	validateTheme(Theme("ocean", "dark", "terminal"));
	Theme old;
	old.preset = "paper"; // deprecated alias
	assert(old.scheme == "paper" && old.preset == "paper");
	assert(designStyles().length == 8 && designStyles()[0].name == "streamlit");
	foreach (dsn; designStyles())
		assert(dsn.label.length && dsn.description.length, dsn.name);
	assert(findDesign("terminal").font == fontTerminal && findDesign("streamlit").font is null);
	assert(designsJson()[1]["tokens"]["baseRadius"].get!string == "0");
	assertThrown(validateTheme(Theme("ocean", "purple")));
	validateTheme(Theme("paper", "dark"));
}
