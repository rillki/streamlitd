/// Text, status and simple display elements.
module streamlitd.elements;

import std.conv : to;
import std.traits;
import vibe.data.json;

import streamlitd.util;
import streamlitd.dataframe : DataFrame;

/// Handle returned by `st.progress`; call `.progress(...)` to update it.
final class ProgressBar
{
	private void delegate(const int[], Json) emitAt;
	private int[] path;

	package this(void delegate(const int[], Json) emitAt, int[] path)
	{
		this.emitAt = emitAt;
		this.path = path;
	}

	/// Update the bar (0..100).
	void progress(int value, string text = null) { emitAt(path, progressElement(value, text)); }
	/// Update the bar (0.0..1.0).
	void progress(double value, string text = null) { emitAt(path, progressElement(value, text)); }
}

package Json progressElement(T)(T value, string text)
{
	double v;
	static if (isIntegral!T)
		v = value / 100.0;
	else
		v = value;
	if (v < 0) v = 0;
	if (v > 1) v = 1;
	return jo("kind", "progress", "value", v, "text", text);
}

/// RAII spinner returned by `st.spinner(text)`; removed when it goes out of scope.
struct Spinner
{
	package void delegate(const int[], Json) send;
	package int[] path;
	@disable this(this);

	~this()
	{
		if (send !is null)
		{
			try
				send(path, jo("kind", "empty"));
			catch (Exception) {}
			send = null;
		}
	}
}

/// An entry of `st.legend`.
struct LegendItem
{
	string label;
	string color;   /// a token ("success", "warning", "error", "info", "muted", "primary") or a hex colour; null: the chart palette
	string shape;   /// "square" (default), "circle", "line" or "diamond"
}

/// An item of `st.feed` (a notification or alert).
struct FeedItem
{
	string title;
	string body;      /// Markdown
	string time;      /// as given, e.g. "09:12" or "2 h ago"
	string type;      /// severity colour: null, "info", "success", "warning" or "error"
	bool unread;      /// shows a dot and a bold title
	string icon;      /// an emoji, or null for the severity's icon
	string[] badges;  /// small labels, e.g. ["ACME", "14 days overdue"]
}

/// An event of `st.timeline`.
struct TimelineItem
{
	string title;
	string time;   /// shown next to the title, as given (e.g. "2026-11-12 09:30", "2 h ago")
	string body;   /// Markdown
	string icon;   /// an emoji or character in the marker (default: a dot)
	string type;   /// marker color: null (primary), "info", "success", "warning" or "error"
}

/// Elements mixed into `St`.
mixin template Elements()
{

	private void headingImpl(int level, string text, string anchor, string help, string divider)
	{
		emit(jo("kind", "heading", "level", level, "body", text, "anchor", anchor, "help", help,
			"divider", divider));
	}

	/// `st.title`
	void title(string text, string anchor = null, string help = null) { headingImpl(1, text, anchor, help, null); }
	/// `st.header`
	void header(string text, string anchor = null, string help = null, string divider = null)
	{
		headingImpl(2, text, anchor, help, divider);
	}
	/// `st.subheader`
	void subheader(string text, string anchor = null, string help = null, string divider = null)
	{
		headingImpl(3, text, anchor, help, divider);
	}

	/// `st.markdown` — GitHub-flavoured Markdown. Raw HTML is escaped unless `unsafeAllowHtml`.
	/// Colours as in Streamlit: `:red[text]`, `:blue-background[text]`, `:green-badge[text]` (a
	/// small label, like `st.badge`).
	void markdown(string body_, bool unsafeAllowHtml = false, string help = null)
	{
		emit(jo("kind", "markdown", "body", body_, "allowHtml", unsafeAllowHtml, "help", help));
	}

	/// `st.caption`
	void caption(string body_, bool unsafeAllowHtml = false)
	{
		emit(jo("kind", "markdown", "body", body_, "allowHtml", unsafeAllowHtml, "caption", true));
	}

	/// `st.text` — fixed-width preformatted text.
	void text(string body_, string help = null) { emit(jo("kind", "text", "body", body_, "help", help)); }

	/// `st.code`
	void code(string body_, string language = "d", bool lineNumbers = false)
	{
		emit(jo("kind", "code", "body", body_, "language", language, "lineNumbers", lineNumbers));
	}

	/// `st.latex` — renders a LaTeX expression with KaTeX (bundled). Markdown also supports
	/// `$inline$` and `$$display$$` math.
	void latex(string body_, string help = null)
	{
		emit(jo("kind", "latex", "body", body_, "help", help));
	}

	/// `st.html` — raw HTML (trusted).
	void html(string body_) { emit(jo("kind", "html", "body", body_)); }

	/// `st.link_button`: a button that opens a URL.
	void linkButton(string label, string url, string help = null, string type = "secondary", string icon = null,
		bool disabled = false, bool useContainerWidth = false)
	{
		emit(jo("kind", "link_button", "label", label, "url", url, "help", help, "type", type, "icon", icon,
			"disabled", disabled, "fullWidth", useContainerWidth));
	}

	/// `st.badge`: a small colored label. Colors: blue, green, orange, red, violet, gray, primary.
	/// Inside Markdown text, write `:blue-badge[label]`.
	void badge(string label, string icon = null, string color = "blue")
	{
		emit(jo("kind", "badge", "label", label, "icon", icon, "color", color));
	}

	/// `st.divider`
	void divider() { emit(jo("kind", "divider")); }

	private void alert(string type, string body_, string icon)
	{
		emit(jo("kind", "alert", "type", type, "body", body_, "icon", icon));
	}

	/// `st.success`
	void success(string body_, string icon = null) { alert("success", body_, icon); }
	/// `st.info`
	void info(string body_, string icon = null) { alert("info", body_, icon); }
	/// `st.warning`
	void warning(string body_, string icon = null) { alert("warning", body_, icon); }
	/// `st.error`
	void error(string body_, string icon = null) { alert("error", body_, icon); }

	/// A notice across the top of the page, above the main content (streamlitd only), e.g. planned
	/// maintenance or "STAGING". `type`: "info", "success", "warning" or "error" (Markdown body).
	/// With `dismissible`, the viewer can close it; it then stays closed in that browser tab until
	/// its text changes, or, with a `key`, until the key changes (so fixing a typo does not show it
	/// again). Call it once per run, like other elements.
	void banner(string body_, string type = "info", bool dismissible = true, string key = null, string icon = null)
	{
		if (type != "info" && type != "success" && type != "warning" && type != "error")
			throw new StreamlitAPIException(`banner() type must be "info", "success", "warning" or "error", not "` ~ type ~ `"`);
		auto b = new St(sess, [cast(int) RootContainer.banner]);
		b.emit(jo("kind", "banner", "type", type, "body", body_, "dismissible", dismissible, "icon", icon,
			"key", key.length ? "k:" ~ key : hashHex(type ~ "\x01" ~ body_)));
	}

	/// A round picture or the initials of `name` (streamlitd only). `size`: "small", "medium" or "large".
	void avatar(string name, string image = null, string size = "medium")
	{
		if (size != "small" && size != "medium" && size != "large")
			throw new StreamlitAPIException(`avatar() size must be "small", "medium" or "large"`);
		emit(jo("kind", "avatar", "name", name, "image", image, "size", size));
	}

	/// Labels and values of one record, in a two-column list (streamlitd only), e.g. a customer's
	/// details. Values are Markdown. `inline: true` puts them side by side in one row (a stat strip).
	void details(string[2][] rows, bool inline = false)
	{
		auto a = Json.emptyArray;
		foreach (r; rows)
			a.appendArrayElement(Json([Json(r[0]), Json(r[1])])); // `~=` would splice the pair in
		emit(jo("kind", "details", "rows", a, "inline", inline));
	}

	/// ditto, from a JSON object: its keys are the labels, in alphabetical order (JSON objects keep
	/// no order; use the `string[2][]` form for your own order). Non-string values are shown as JSON.
	void details(Json record, bool inline = false)
	{
		import std.algorithm : sort;
		auto a = Json.emptyArray;
		if (record.type != Json.Type.object)
			throw new StreamlitAPIException("details() needs a JSON object (or label/value pairs)");
		string[] keys;
		foreach (string k, v; record)
			keys ~= k;
		foreach (k; keys.sort)
		{
			auto v = record[k];
			a.appendArrayElement(Json([Json(k), Json(v.type == Json.Type.string ? v.get!string : v.toString)]));
		}
		emit(jo("kind", "details", "rows", a, "inline", inline));
	}

	/// Progress through a sequence of steps (streamlitd only), e.g. a multi-step form. `current` is
	/// the index of the current step (0-based); steps before it are shown as done, and
	/// `current == steps.length` shows all as done. `orientation`: "horizontal" or "vertical".
	void stepper(string[] steps, size_t current, string orientation = "horizontal")
	{
		if (orientation != "horizontal" && orientation != "vertical")
			throw new StreamlitAPIException(`stepper() orientation must be "horizontal" or "vertical"`);
		if (current > steps.length)
			current = steps.length;
		emit(jo("kind", "stepper", "steps", steps, "current", current, "orientation", orientation));
	}

	/// A placeholder that shows content is loading (streamlitd only): `lines` text lines, or a block
	/// of `height` pixels. Typical use: `auto ph = st.empty(); ph.skeleton(); ...; ph.dataframe(df);`.
	void skeleton(int lines = 3, int height = 0)
	{
		emit(jo("kind", "skeleton", "lines", lines < 1 ? 1 : lines, "height", height < 0 ? 0 : height));
	}

	/// A vertical list of events (streamlitd only), newest or oldest first as given.
	void timeline(TimelineItem[] items)
	{
		auto a = Json.emptyArray;
		foreach (it; items)
		{
			if (it.type.length && it.type != "info" && it.type != "success" && it.type != "warning" && it.type != "error")
				throw new StreamlitAPIException(`timeline() item type must be "info", "success", "warning" or "error"`);
			a ~= jo("title", it.title, "time", it.time, "body", it.body, "icon", it.icon, "type", it.type);
		}
		emit(jo("kind", "timeline", "items", a));
	}

	/// A button that reruns the whole app, like ⟳ in the header (streamlitd only). Place it anywhere,
	/// e.g. `st.sidebar.rerunButton()` with `[ui] rerunButton = "hidden"`.
	void rerunButton(string label = "Rerun", string icon = "⟳", string help = null)
	{
		emit(jo("kind", "rerun_button", "label", label, "icon", icon, "help", help));
	}

	/// A button that opens the viewer's appearance panel (mode, design style, color scheme) next to
	/// it, like ⚙ in the header (streamlitd only). It shows nothing while the app does not let
	/// viewers change the appearance (`[theme] allowSwitch = false`).
	void settingsButton(string label = "Appearance", string icon = "⚙", string help = null)
	{
		emit(jo("kind", "settings_button", "label", label, "icon", icon, "help", help));
	}

	/// `st.exception`
	void exception(Throwable e)
	{
		string trace;
		try
			trace = e.info is null ? null : e.info.toString();
		catch (Exception) {}
		emit(jo("kind", "exception", "type", typeid(e).name, "message", e.msg,
			"file", e.file, "line", e.line, "trace", trace));
	}

	/// `st.metric`. `delta` starting with "-" is shown as a decrease.
	/// `chartData` draws a small trend chart under the value (`chartType`: "line", "bar" or
	/// "area"); `caption` adds a small line, e.g. "was 1,204 on 01.10" (streamlitd only).
	void metric(string label, string value, string delta = null, string deltaColor = "normal",
		string help = null, bool border = false, double[] chartData = null, string chartType = "line",
		string caption = null)
	{
		if (chartType != "line" && chartType != "bar" && chartType != "area")
			throw new StreamlitAPIException(`metric() chartType must be "line", "bar" or "area"`);
		emit(jo("kind", "metric", "label", label, "value", value, "delta", delta, "deltaColor", deltaColor,
			"help", help, "border", border, "chartData", chartData, "chartType", chartType, "caption", caption));
	}

	/// ditto (an exact `int` overload, so int values are not ambiguous between long and double)
	void metric(string label, int value, string delta = null, string deltaColor = "normal",
		string help = null, bool border = false, double[] chartData = null, string chartType = "line",
		string caption = null)
	{
		metric(label, value.to!string, delta, deltaColor, help, border, chartData, chartType, caption);
	}

	/// ditto
	void metric(string label, long value, string delta = null, string deltaColor = "normal",
		string help = null, bool border = false, double[] chartData = null, string chartType = "line",
		string caption = null)
	{
		metric(label, value.to!string, delta, deltaColor, help, border, chartData, chartType, caption);
	}

	/// ditto
	void metric(string label, double value, string delta = null, string deltaColor = "normal",
		string help = null, bool border = false, double[] chartData = null, string chartType = "line",
		string caption = null)
	{
		metric(label, format("%g", value), delta, deltaColor, help, border, chartData, chartType, caption);
	}

	/// A placeholder for "nothing here yet" (streamlitd only): an icon, a title and a Markdown body,
	/// e.g. when a filter matches no rows.
	void emptyState(string title, string body_ = null, string icon = "🗂️")
	{
		emit(jo("kind", "empty_state", "title", title, "body", body_, "icon", icon));
	}

	/// A legend for charts and colour-coded tables (streamlitd only).
	void legend(LegendItem[] items, string title = null)
	{
		auto a = Json.emptyArray;
		foreach (it; items)
		{
			if (it.shape.length && it.shape != "square" && it.shape != "circle" && it.shape != "line" && it.shape != "diamond")
				throw new StreamlitAPIException(`legend() shape must be "square", "circle", "line" or "diamond"`);
			a.appendArrayElement(jo("label", it.label, "color", it.color, "shape", it.shape.length ? it.shape : "square"));
		}
		emit(jo("kind", "legend", "items", a, "title", title));
	}

	/// A bar split into parts in proportion to `values`, with a legend (streamlitd only), e.g. the
	/// share of stock per status. `colors`: tokens ("success", "warning", "error", "info", "muted",
	/// "primary") or hex colours; default: the chart palette.
	void proportionBar(double[] values, string[] labels, string[] colors = null, string format = null)
	{
		if (labels.length != values.length)
			throw new StreamlitAPIException("proportionBar(): one label per value");
		if (colors.length && colors.length != values.length)
			throw new StreamlitAPIException("proportionBar(): one colour per value (or none)");
		foreach (v; values)
			if (v < 0)
				throw new StreamlitAPIException("proportionBar(): values must not be negative");
		emit(jo("kind", "proportion_bar", "values", values, "labels", labels, "colors", colors, "format", format));
	}

	/// A list of notifications or alerts (streamlitd only): each with a title, a Markdown body, a
	/// time, a severity colour, an unread dot and small badges.
	void feed(FeedItem[] items)
	{
		auto a = Json.emptyArray;
		foreach (it; items)
		{
			if (it.type.length && it.type != "info" && it.type != "success" && it.type != "warning" && it.type != "error")
				throw new StreamlitAPIException(`feed() item type must be "info", "success", "warning" or "error"`);
			a.appendArrayElement(jo("title", it.title, "body", it.body, "time", it.time, "type", it.type, "unread", it.unread,
				"icon", it.icon, "badges", it.badges));
		}
		emit(jo("kind", "feed", "items", a));
	}

	/// `st.json` — a collapsible JSON viewer.
	void json(Json value, bool expanded = true)
	{
		emit(jo("kind", "json", "value", value, "expanded", expanded));
	}

	/// ditto, from JSON text (shown as a string if it does not parse).
	void json(string jsonText, bool expanded = true)
	{
		Json j;
		try
			j = parseJsonString(jsonText);
		catch (Exception)
			j = Json(jsonText);
		json(j, expanded);
	}

	/// `st.json` for any D value (struct, class, array, associative array ...), serialized to JSON.
	/// Use `jsonOf!T(value, expanded: false)` when passing named arguments.
	void jsonOf(T)(T value, bool expanded = true)
	{
		json(toJ(value), expanded);
	}

	/// `st.progress` — `value` in 0..100; returns a handle that can be updated.
	ProgressBar progress(int value, string text = null)
	{
		auto p = emit(progressElement(value, text));
		return new ProgressBar((const int[] pp, Json el) { emitAt(pp, el); }, p);
	}

	/// `st.progress` — `value` in 0.0..1.0.
	ProgressBar progress(double value, string text = null)
	{
		auto p = emit(progressElement(value, text));
		return new ProgressBar((const int[] pp, Json el) { emitAt(pp, el); }, p);
	}

	/// `st.spinner` — keep the returned value alive while working:
	/// `{ auto s = st.spinner("Loading..."); work(); }`
	Spinner spinner(string text = "In progress...")
	{
		auto p = emit(jo("kind", "spinner", "text", text));
		auto s = sess;
		Spinner sp;
		sp.path = p;
		sp.send = (const int[] pp, Json el) { s.sendDelta(pp, el); };
		return sp;
	}

	/// `st.spinner` with a body.
	void spinner(string text, scope void delegate() body_)
	{
		auto s = spinner(text);
		body_();
	}

	/// `st.write` — renders each argument depending on its type.
	void write(Args...)(Args args)
	{
		string pending;
		void flush()
		{
			if (pending.length)
				markdown(pending);
			pending = null;
		}
		foreach (a; args)
		{
			alias A = typeof(a);
			static if (isSomeString!A)
				pending ~= (pending.length ? " " : "") ~ a.to!string;
			else static if (is(A : DataFrame))
			{
				flush();
				dataframe(a);
			}
			else static if (is(A == Json))
			{
				flush();
				json(a);
			}
			else static if (isNumeric!A || is(A == bool))
				pending ~= (pending.length ? " " : "") ~ "`" ~ a.to!string ~ "`";
			else static if (is(A : Throwable))
			{
				flush();
				exception(a);
			}
			else static if (is(A == struct) || is(A == class) || isArray!A || isAssociativeArray!A)
			{
				flush();
				jsonOf(a);
			}
			else
				pending ~= (pending.length ? " " : "") ~ a.to!string;
		}
		flush();
	}
}
