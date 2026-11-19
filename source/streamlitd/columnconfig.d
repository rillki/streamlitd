/// Column configuration for `st.dataframe`, `st.dataEditor` and `st.table` (Streamlit's
/// `st.column_config`): labels, display formats, widths, tooltips, pinned and hidden columns,
/// column types with their editors, colours, grouped headers.
///
/// ---
/// alias C = ColumnConfig;
/// st.dataframe(df, columnConfig: [
///     "amount": C.number("Amount", format: "localized"),
///     "share":  C.number("Share", format: "%.1f%%", color: "sign"),
///     "due":    C.date("Due", format: "DD.MM.YYYY"),
///     "guid":   C.hide(),
/// ]);
/// ---
module streamlitd.columnconfig;

import std.math : isNaN;
import vibe.data.json;

/// How one column is shown (and edited). Make one with the static functions (`ColumnConfig.number`,
/// `ColumnConfig.date`, ...); every argument is optional.
struct ColumnConfig
{
	/// "auto" (from the data), "text", "number", "date", "datetime", "time", "checkbox",
	/// "select", "progress" or "link".
	string type = "auto";
	/// Not shown. The data stays available: as a `detailColumn`, a selection's `rowKey`, in
	/// `cellStyle`.
	bool hidden;
	string label;       /// header text (default: the column name)
	string help;        /// tooltip on the header
	string width;       /// "small", "medium", "large", or pixels ("120")
	bool pinned;        /// stays visible on the left while scrolling sideways
	bool disabled;      /// read-only in `st.dataEditor`
	string group;       /// adjacent columns with the same group share a header above them
	/// Display format.
	/// - numbers: printf style (`"%d"`, `"%.1f%%"`, `"%+.0f"`, `"%,.2f"` with thousands
	///   separators) or `"localized"`, `"plain"`, `"percent"` (×100 and %), `"compact"` (1.2K),
	///   `"dollar"`, `"euro"`;
	/// - dates and times: `"DD.MM.YYYY"`, `"MM.YYYY"`, `"YYYY-MM-DD HH:mm"`, ... or
	///   `"localized"`;
	/// - progress: the number format of the label.
	string format;
	double min = double.nan;  /// number, progress: smallest value (editor, bar scale, heat scale)
	double max = double.nan;  /// ditto, largest value
	double step = double.nan; /// number editor step
	size_t maxChars;          /// text editor limit
	string[] options;         /// select: the choices
	bool required;            /// editor: the cell may not be left empty
	/// Text colour: `"sign"` (positive green, negative red), or a token `"success"`, `"warning"`,
	/// `"error"`, `"info"`, `"muted"`, `"primary"`.
	string color;
	/// Background: a token (as `color`), a colour (`"#fff3cd"`), or `"heat"` (from light to the
	/// theme's primary colour between the column's smallest and largest value).
	string background;
	/// A second, smaller line in each cell, taken from this column (e.g. "% of base").
	string detailColumn;
	/// link: the text shown instead of the URL.
	string displayText;

	/// A text column.
	static ColumnConfig text(string label = null, string help = null, string width = null, bool pinned = false,
		bool disabled = false, size_t maxChars = 0, bool required = false, string color = null,
		string background = null, string group = null, bool hidden = false)
	{
		ColumnConfig c;
		c.type = "text";
		c.label = label; c.help = help; c.width = width; c.pinned = pinned; c.disabled = disabled;
		c.maxChars = maxChars; c.required = required; c.color = color; c.background = background; c.group = group;
		c.hidden = hidden;
		return c;
	}

	/// A number column.
	static ColumnConfig number(string label = null, string format = null, string help = null, string width = null,
		double min = double.nan, double max = double.nan, double step = double.nan, bool pinned = false,
		bool disabled = false, bool required = false, string color = null, string background = null,
		string detailColumn = null, string group = null, bool hidden = false)
	{
		ColumnConfig c;
		c.type = "number";
		c.hidden = hidden;
		c.label = label; c.format = format; c.help = help; c.width = width; c.min = min; c.max = max;
		c.step = step; c.pinned = pinned; c.disabled = disabled; c.required = required; c.color = color;
		c.background = background; c.detailColumn = detailColumn; c.group = group;
		return c;
	}

	/// A date column (values "YYYY-MM-DD").
	static ColumnConfig date(string label = null, string format = null, string help = null, string width = null,
		bool pinned = false, bool disabled = false, bool required = false, string group = null)
	{
		ColumnConfig c;
		c.type = "date";
		c.label = label; c.format = format; c.help = help; c.width = width; c.pinned = pinned;
		c.disabled = disabled; c.required = required; c.group = group;
		return c;
	}

	/// A date-and-time column (values "YYYY-MM-DDTHH:MM:SS").
	static ColumnConfig datetime(string label = null, string format = null, string help = null, string width = null,
		bool pinned = false, bool disabled = false, string group = null)
	{
		ColumnConfig c;
		c.type = "datetime";
		c.label = label; c.format = format; c.help = help; c.width = width; c.pinned = pinned;
		c.disabled = disabled; c.group = group;
		return c;
	}

	/// A time column (values "HH:MM" or "HH:MM:SS").
	static ColumnConfig time(string label = null, string format = null, string help = null, string width = null,
		bool disabled = false, string group = null)
	{
		ColumnConfig c;
		c.type = "time";
		c.label = label; c.format = format; c.help = help; c.width = width; c.disabled = disabled; c.group = group;
		return c;
	}

	/// A true/false column (a checkbox in the editor).
	static ColumnConfig checkbox(string label = null, string help = null, string width = null, bool disabled = false,
		string group = null)
	{
		ColumnConfig c;
		c.type = "checkbox";
		c.label = label; c.help = help; c.width = width; c.disabled = disabled; c.group = group;
		return c;
	}

	/// A column whose values come from `options` (a themed drop-down in the editor).
	static ColumnConfig select(string label = null, string[] options = null, bool required = false,
		string help = null, string width = null, bool disabled = false, string group = null)
	{
		ColumnConfig c;
		c.type = "select";
		c.label = label; c.options = options; c.required = required; c.help = help; c.width = width;
		c.disabled = disabled; c.group = group;
		return c;
	}

	/// A progress bar between `min` and `max`, with the value as its label.
	static ColumnConfig progress(string label = null, double min = 0, double max = 100, string format = null,
		string help = null, string width = null, string group = null)
	{
		ColumnConfig c;
		c.type = "progress";
		c.label = label; c.min = min; c.max = max; c.format = format; c.help = help; c.width = width; c.group = group;
		return c;
	}

	/// A link (the URL is the value); `displayText` replaces the URL in the cell.
	static ColumnConfig link(string label = null, string displayText = null, string help = null,
		string width = null, string group = null)
	{
		ColumnConfig c;
		c.type = "link";
		c.label = label; c.displayText = displayText; c.help = help; c.width = width; c.group = group;
		return c;
	}

	/// Only a header label, tooltip, width or group; the type comes from the data.
	static ColumnConfig column(string label = null, string help = null, string width = null, bool pinned = false,
		bool disabled = false, string group = null)
	{
		ColumnConfig c;
		c.label = label; c.help = help; c.width = width; c.pinned = pinned; c.disabled = disabled; c.group = group;
		return c;
	}

	/// A column that is not shown (see the `hidden` field).
	static ColumnConfig hide()
	{
		ColumnConfig c;
		c.hidden = true;
		return c;
	}

	/// The JSON sent to the browser.
	Json toJson() const
	{
		auto j = Json.emptyObject;
		void s(string k, string v) { if (v.length) j[k] = v; }
		s("type", type == "auto" ? null : type);
		s("label", label); s("help", help); s("width", width); s("format", format); s("group", group);
		s("color", color); s("background", background); s("detail", detailColumn); s("display", displayText);
		if (hidden) j["hidden"] = true;
		if (pinned) j["pinned"] = true;
		if (disabled) j["disabled"] = true;
		if (required) j["required"] = true;
		if (!isNaN(min)) j["min"] = min;
		if (!isNaN(max)) j["max"] = max;
		if (!isNaN(step)) j["step"] = step;
		if (maxChars) j["maxChars"] = maxChars;
		if (options.length)
		{
			auto a = Json.emptyArray;
			foreach (o; options)
				a.appendArrayElement(Json(o));
			j["options"] = a;
		}
		return j;
	}
}

/// Check a configuration against the frame's columns and turn it into JSON (`config`), plus the
/// totals spec (`totals`). Throws on unknown columns and invalid values, so typos show up.
package Json columnConfigJson(const string[] columns, const ColumnConfig[string] config, const string[string] totals,
	string what)
{
	import std.algorithm : canFind;
	import streamlitd.errors : StreamlitAPIException;
	static immutable types = ["auto", "text", "number", "date", "datetime", "time", "checkbox", "select", "progress",
		"link"];
	static immutable aggs = ["sum", "mean", "min", "max", "count"];
	auto cfg = Json.emptyObject;
	foreach (name, c; config)
	{
		if (!columns.canFind(name))
			throw new StreamlitAPIException(what ~ `: columnConfig names an unknown column "` ~ name ~ `"`);
		if (!types.canFind(c.type))
			throw new StreamlitAPIException(what ~ `: unknown column type "` ~ c.type ~ `"`);
		if (c.detailColumn.length && !columns.canFind(c.detailColumn))
			throw new StreamlitAPIException(what ~ `: detailColumn "` ~ c.detailColumn ~ `" is not a column`);
		if (c.width.length && !["small", "medium", "large"].canFind(c.width))
		{
			foreach (ch; c.width)
				if (ch < '0' || ch > '9')
					throw new StreamlitAPIException(what ~ `: width must be "small", "medium", "large" or pixels, not "` ~ c.width ~ `"`);
		}
		cfg[name] = c.toJson();
	}
	auto tot = Json.emptyObject;
	foreach (name, a; totals)
	{
		if (!columns.canFind(name))
			throw new StreamlitAPIException(what ~ `: totals names an unknown column "` ~ name ~ `"`);
		tot[name] = a; // an aggregation, or text shown as is (e.g. "Total")
	}
	return Json(["config": cfg, "totals": tot]);
}

/// Is `a` an aggregation for totals (else it is a label)?
package bool isAggregation(string a)
{
	return a == "sum" || a == "mean" || a == "min" || a == "max" || a == "count";
}

unittest
{
	auto c = ColumnConfig.number("Amount", format: "%.1f%%", min: 0, color: "sign");
	auto j = c.toJson();
	assert(j["type"].get!string == "number" && j["label"].get!string == "Amount" && j["min"].get!double == 0);
	assert(j["max"].type == Json.Type.undefined && j["color"].get!string == "sign");
	import std.exception : assertThrown;
	assertThrown(columnConfigJson(["a"], ["b": ColumnConfig.text()], null, "dataframe()"));
	assert(ColumnConfig.number(format: "%d", hidden: true).toJson()["hidden"].get!bool);
	assertThrown(columnConfigJson(["a"], ["a": ColumnConfig.text(width: "wide")], null, "dataframe()"));
	assertThrown(columnConfigJson(["a"], null, ["b": "sum"], "dataframe()"));
	auto ok = columnConfigJson(["a", "b"], ["a": ColumnConfig.hide()], ["b": "sum", "a": "Total"], "dataframe()");
	assert(ok["config"]["a"]["hidden"].get!bool && ok["totals"]["b"].get!string == "sum");
}
