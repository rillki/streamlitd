/// Input widgets.
module streamlitd.widgets;

import std.conv : to;
import std.traits;
import std.datetime : Date, TimeOfDay, Clock;
import vibe.data.json;

import streamlitd.util;

package string[] formatOptions(T)(const T[] options, string delegate(T) fmt)
{
	string[] r;
	foreach (o; options)
		r ~= fmt !is null ? fmt(cast(T) o) : displayString(o);
	return r;
}

package Json numJ(T)(T v)
{
	return toJ(v);
}

package T jNum(T)(Json j)
{
	static if (isIntegral!T)
	{
		if (j.type == Json.Type.int_)
			return cast(T) j.get!long;
		if (j.type == Json.Type.float_)
			return cast(T) j.get!double;
		if (j.type == Json.Type.bigInt)
			return cast(T) j.get!long;
		if (j.type == Json.Type.string)
			return j.get!string.to!T;
	}
	else
	{
		if (j.type == Json.Type.float_)
			return cast(T) j.get!double;
		if (j.type == Json.Type.int_)
			return cast(T) j.get!long;
		if (j.type == Json.Type.string)
			return j.get!string.to!T;
	}
	throw new Exception("not a number");
}

/// Truncate to at most `maxChars` characters (0 = unlimited).
package string limitChars(string s, size_t maxChars)
{
	import std.utf : toUTF32, toUTF8;
	if (maxChars == 0)
		return s;
	auto d = s.toUTF32;
	return d.length > maxChars ? d[0 .. maxChars].toUTF8 : s;
}

package string dateStr(Date d) { return d.toISOExtString(); }
package Date strDate(string s) { return Date.fromISOExtString(s); }
package string timeStr(TimeOfDay t)
{
	import std.format : format;
	return format("%02d:%02d", t.hour, t.minute);
}
package TimeOfDay strTime(string s)
{
	import std.array : split;
	auto p = s.split(":");
	return TimeOfDay(p[0].to!int, p[1].to!int, p.length > 2 ? p[2].to!int : 0);
}

/// A node of `st.treeSelect`.
struct TreeNode
{
	string id;       /// returned when selected; unique in the tree
	string label;
	TreeNode[] children;
}

/// A date range from `st.dateRangeInput` (`start <= end`, both included).
struct DateRange
{
	Date start;
	Date end;
}

package void collectTreeIds(const TreeNode[] nodes, ref bool[string] ids)
{
	import streamlitd.errors : StreamlitAPIException;
	foreach (n; nodes)
	{
		if (n.id in ids)
			throw new StreamlitAPIException(`treeSelect(): duplicate node id "` ~ n.id ~ `"`);
		ids[n.id] = true;
		collectTreeIds(n.children, ids);
	}
}

package Json treeJson(const TreeNode[] nodes)
{
	auto a = Json.emptyArray;
	foreach (n; nodes)
	{
		auto o = Json.emptyObject;
		o["id"] = n.id;
		o["label"] = n.label;
		if (n.children.length)
			o["children"] = treeJson(n.children);
		a ~= o;
	}
	return a;
}

/// The value of a tree select, as the browser keeps it: in `multi` mode a picked node stands for its
/// whole subtree and a parent is picked exactly when all its children are; the ids come in tree
/// order (pre-order). Single mode: the first id that is in the tree. Unknown ids are dropped.
package string[] normalizeTree(const TreeNode[] nodes, const string[] ids, bool multi)
{
	bool[string] want;
	foreach (x; ids)
		want[x] = true;
	string[] r;
	if (!multi)
	{
		bool[string] all;
		collectTreeIds(nodes, all);
		foreach (x; ids)
			if (x in all)
				return [x];
		return null;
	}
	// returns whether `n` ends up checked; `inherited`: an ancestor was picked
	bool walk(const TreeNode n, bool inherited, ref string[] outIds)
	{
		immutable picked = inherited || (n.id in want) !is null;
		if (!n.children.length)
		{
			if (picked)
				outIds ~= n.id;
			return picked;
		}
		string[] sub;
		bool all = true;
		foreach (c; n.children)
			all = walk(c, picked, sub) && all;
		if (all)
			outIds ~= n.id;
		outIds ~= sub;
		return all;
	}
	foreach (n; nodes)
		walk(n, false, r);
	return r;
}

/// Widgets mixed into `St`.
mixin template Widgets()
{

	private Json commonProps(string label, string help, bool disabled, string labelVisibility)
	{
		return jo("label", label, "help", help, "disabled", disabled, "labelVisibility", labelVisibility);
	}

	/// `st.button` — true only on the run triggered by the click.
	bool button(string label, string key = null, string help = null, void delegate() onClick = null,
		bool disabled = false, string type = "secondary", bool useContainerWidth = false, string icon = null)
	{
		auto id = widgetId("button", key, label);
		auto p = commonProps(label, help, disabled, "visible");
		p["type"] = type;
		p["fullWidth"] = useContainerWidth;
		p["icon"] = icon;
		return widget!bool("button", id, key, false, (bool v) => Json(v), (Json j) => true, onClick, p, true);
	}

	/// A button that opens a menu of actions (streamlitd only). Returns the item picked in this run,
	/// otherwise null, like `button`. An item `"-"` is a separator.
	/// ---
	/// switch (st.menuButton("Export", ["CSV", "Excel", "-", "Print"]))
	/// { case "CSV": ...; default: }
	/// ---
	string menuButton(string label, string[] items, string icon = null, string type = "secondary", string key = null,
		string help = null, bool disabled = false, void delegate() onClick = null)
	{
		auto id = widgetId("menu_button", key, label, items.join("\x01"));
		auto p = commonProps(label, help, disabled, "visible");
		p["items"] = toJ(items);
		p["type"] = type;
		p["icon"] = icon;
		return widget!string("menu_button", id, key, null, (string v) => Json(v), (Json j) {
			auto s = j.get!string;
			foreach (it; items)
				if (it == s && it != "-")
					return s;
			throw new StreamlitAPIException("not a menu item");
		}, onClick, p, true);
	}

	/// Page buttons (‹ 1 2 … 9 ›) for long tables and lists (streamlitd only). Returns the selected
	/// page, starting at 1; it stays within the pages when `totalItems` shrinks.
	/// ---
	/// auto page = st.pagination(rows.length, 20);
	/// st.table(rows[(page - 1) * 20 .. min(page * 20, rows.length)]);
	/// ---
	size_t pagination(size_t totalItems, size_t pageSize = 10, string key = null, void delegate() onChange = null,
		bool disabled = false, string label = "Pages")
	{
		if (pageSize == 0)
			throw new StreamlitAPIException("pagination() pageSize must be at least 1");
		immutable pages = totalItems == 0 ? 1 : (totalItems + pageSize - 1) / pageSize;
		size_t clamp(long v) { return v < 1 ? 1 : v > pages ? pages : cast(size_t) v; }
		auto id = widgetId("pagination", key, label, pageSize.to!string);
		auto p = commonProps(label, null, disabled, "collapsed");
		p["pages"] = pages;
		p["total"] = totalItems;
		p["pageSize"] = pageSize;
		auto v = widget!size_t("pagination", id, key, 1, (size_t v) => Json(clamp(v)), (Json j) => clamp(j.get!long), onChange, p);
		return clamp(v);
	}

	/// `st.form_submit_button` — must be called inside `st.form`.
	bool formSubmitButton(string label = "Submit", string help = null, void delegate() onClick = null,
		string type = "secondary", bool disabled = false, bool useContainerWidth = false, string icon = null)
	{
		if (formId.length == 0)
			throw new StreamlitAPIException("`formSubmitButton()` must be used inside an `st.form()`.");
		auto id = widgetId("form_submit_button", null, label, formId);
		auto p = commonProps(label, help, disabled, "visible");
		p["type"] = type;
		p["fullWidth"] = useContainerWidth;
		p["icon"] = icon;
		auto r = widget!bool("form_submit_button", id, null, false, (bool v) => Json(v), (Json j) => true,
			onClick, p, true);
		if (formClear == formId)
			sess.newWidgetMeta[id].clearsForm = formId;
		return r;
	}

	private bool boolWidget(string kind, string label, bool value, string key, string help,
		void delegate() onChange, bool disabled, string labelVisibility)
	{
		auto id = widgetId(kind, key, label);
		return widget!bool(kind, id, key, value, (bool v) => Json(v), (Json j) => j.get!bool, onChange,
			commonProps(label, help, disabled, labelVisibility));
	}

	/// `st.checkbox`
	bool checkbox(string label, bool value = false, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string labelVisibility = "visible")
	{
		return boolWidget("checkbox", label, value, key, help, onChange, disabled, labelVisibility);
	}

	/// `st.toggle`
	bool toggle(string label, bool value = false, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string labelVisibility = "visible")
	{
		return boolWidget("toggle", label, value, key, help, onChange, disabled, labelVisibility);
	}

	private T indexWidget(T)(string kind, string label, T[] options, ptrdiff_t index, string key,
		string help, void delegate() onChange, bool disabled, string delegate(T) formatFunc,
		string labelVisibility, Json extra)
	{
		auto labels = formatOptions(options, formatFunc);
		auto id = widgetId(kind, key, [label] ~ labels);
		auto p = commonProps(label, help, disabled, labelVisibility);
		p["options"] = toJ(labels);
		foreach (string k, v; extra)
			p[k] = v;
		auto n = cast(ptrdiff_t) options.length;
		ptrdiff_t def = (index >= 0 && index < n) ? index : -1;
		auto idx = widget!ptrdiff_t(kind, id, key, def,
			(ptrdiff_t i) => i < 0 ? Json(null) : Json(cast(long) i),
			(Json j) {
				if (j.type == Json.Type.null_) return cast(ptrdiff_t) -1;
				auto i = jNum!ptrdiff_t(j);
				if (i < 0 || i >= n) throw new Exception("index out of range");
				return i;
			}, onChange, p);
		return idx < 0 ? T.init : options[idx];
	}

	/// `st.radio`
	string radio(string label, string[] options, size_t index = 0, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, bool horizontal = false,
		string labelVisibility = "visible", string[] captions = null)
	{
		return radioOf!string(label, options, index, key, help, onChange, disabled, horizontal, null,
			labelVisibility, captions);
	}

	/// `st.radio` over any option type (use `radioOf!T(...)` when passing named arguments).
	T radioOf(T)(string label, T[] options, size_t index = 0, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, bool horizontal = false,
		string delegate(T) formatFunc = null, string labelVisibility = "visible", string[] captions = null)
	{
		return indexWidget!T("radio", label, options, cast(ptrdiff_t) index, key, help, onChange, disabled,
			formatFunc, labelVisibility, jo("horizontal", horizontal, "captions", captions));
	}

	/// `st.selectbox`. Pass `index = -1` to start with no selection (returns `null`).
	string selectbox(string label, string[] options, ptrdiff_t index = 0, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string placeholder = "Choose an option",
		string labelVisibility = "visible")
	{
		return selectboxOf!string(label, options, index, key, help, onChange, disabled, placeholder, null,
			labelVisibility);
	}

	/// `st.selectbox` over any option type (returns `T.init` when nothing is selected).
	T selectboxOf(T)(string label, T[] options, ptrdiff_t index = 0, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string placeholder = "Choose an option",
		string delegate(T) formatFunc = null, string labelVisibility = "visible")
	{
		return indexWidget!T("selectbox", label, options, index, key, help, onChange, disabled,
			formatFunc, labelVisibility, jo("placeholder", placeholder));
	}

	/// `st.select_slider`
	string selectSlider(string label, string[] options, size_t index = 0, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string labelVisibility = "visible")
	{
		return selectSliderOf!string(label, options, index, key, help, onChange, disabled, null, labelVisibility);
	}

	/// `st.select_slider` over any option type.
	T selectSliderOf(T)(string label, T[] options, size_t index = 0, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string delegate(T) formatFunc = null,
		string labelVisibility = "visible")
	{
		return indexWidget!T("select_slider", label, options, cast(ptrdiff_t) index, key, help, onChange,
			disabled, formatFunc, labelVisibility, Json.emptyObject);
	}

	/// `st.multiselect`
	string[] multiselect(string label, string[] options, string[] default_ = null, string key = null,
		string help = null, void delegate() onChange = null, bool disabled = false, size_t maxSelections = 0,
		string placeholder = "Choose options", string labelVisibility = "visible")
	{
		return multiselectOf!string(label, options, default_, key, help, onChange, disabled, maxSelections,
			placeholder, null, labelVisibility);
	}

	/// `st.multiselect` over any option type.
	T[] multiselectOf(T)(string label, T[] options, T[] default_ = null, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, size_t maxSelections = 0,
		string placeholder = "Choose options", string delegate(T) formatFunc = null,
		string labelVisibility = "visible")
	{
		auto labels = formatOptions(options, formatFunc);
		auto id = widgetId("multiselect", key, [label] ~ labels);
		auto p = commonProps(label, help, disabled, labelVisibility);
		p["options"] = toJ(labels);
		p["maxSelections"] = maxSelections;
		p["placeholder"] = placeholder;
		long[] def;
		foreach (d; default_)
			foreach (i, o; options)
				if (o == d)
				{
					def ~= i;
					break;
				}
		auto n = options.length;
		auto idx = widget!(long[])("multiselect", id, key, def, (long[] v) => toJ(v), (Json j) {
			long[] r;
			foreach (e; j)
			{
				auto i = jNum!long(e);
				if (i < 0 || i >= n) throw new Exception("index out of range");
				r ~= i;
			}
			if (maxSelections > 0 && r.length > maxSelections)
				r = r[0 .. maxSelections];
			return r;
		}, onChange, p);
		T[] res;
		foreach (i; idx)
			res ~= options[i];
		return res;
	}

	/// `st.slider` (int)
	int slider(string label, int minValue, int maxValue, int value, int step = 1, string key = null,
		string help = null, void delegate() onChange = null, bool disabled = false, string format = null,
		string labelVisibility = "visible")
	{
		return sliderImpl!int(label, minValue, maxValue, value, step, key, help, onChange, disabled, format,
			labelVisibility);
	}

	/// `st.slider` (long)
	long slider(string label, long minValue, long maxValue, long value, long step = 1, string key = null,
		string help = null, void delegate() onChange = null, bool disabled = false, string format = null,
		string labelVisibility = "visible")
	{
		return sliderImpl!long(label, minValue, maxValue, value, step, key, help, onChange, disabled, format,
			labelVisibility);
	}

	/// `st.slider` (double)
	double slider(string label, double minValue, double maxValue, double value, double step = 0.01,
		string key = null, string help = null, void delegate() onChange = null, bool disabled = false,
		string format = null, string labelVisibility = "visible")
	{
		return sliderImpl!double(label, minValue, maxValue, value, step, key, help, onChange, disabled, format,
			labelVisibility);
	}

	/// `st.slider` with an int range `[low, high]`.
	int[2] slider(string label, int minValue, int maxValue, int[2] value, int step = 1, string key = null,
		string help = null, void delegate() onChange = null, bool disabled = false, string format = null,
		string labelVisibility = "visible")
	{
		return sliderRangeImpl!int(label, minValue, maxValue, value, step, key, help, onChange, disabled, format,
			labelVisibility);
	}

	/// `st.slider` with a double range `[low, high]`.
	double[2] slider(string label, double minValue, double maxValue, double[2] value, double step = 0.01,
		string key = null, string help = null, void delegate() onChange = null, bool disabled = false,
		string format = null, string labelVisibility = "visible")
	{
		return sliderRangeImpl!double(label, minValue, maxValue, value, step, key, help, onChange, disabled,
			format, labelVisibility);
	}

	private T sliderImpl(T)(string label, T minValue, T maxValue, T value, T step = T.init, string key = null,
		string help = null, void delegate() onChange = null, bool disabled = false, string format = null,
		string labelVisibility = "visible") if (isNumeric!T)
	{
		static if (isIntegral!T)
			T st_ = step == T.init ? 1 : step;
		else
			T st_ = (step != step || step == 0) ? cast(T) 0.01 : step; // NaN init for floats
		auto id = widgetId("slider", key, label, minValue.to!string, maxValue.to!string, st_.to!string);
		auto p = commonProps(label, help, disabled, labelVisibility);
		p["min"] = numJ(minValue);
		p["max"] = numJ(maxValue);
		p["step"] = numJ(st_);
		p["format"] = format;
		p["isInt"] = isIntegral!T;
		p["range"] = false;
		return widget!T("slider", id, key, value, (T v) => numJ(v), (Json j) {
			auto v = jNum!T(j);
			if (v < minValue) v = minValue;
			if (v > maxValue) v = maxValue;
			return v;
		}, onChange, p);
	}

	private T[2] sliderRangeImpl(T)(string label, T minValue, T maxValue, T[2] value, T step = T.init, string key = null,
		string help = null, void delegate() onChange = null, bool disabled = false, string format = null,
		string labelVisibility = "visible") if (isNumeric!T)
	{
		static if (isIntegral!T)
			T st_ = step == T.init ? 1 : step;
		else
			T st_ = (step != step || step == 0) ? cast(T) 0.01 : step;
		auto id = widgetId("slider", key, label, "range", minValue.to!string, maxValue.to!string, st_.to!string);
		auto p = commonProps(label, help, disabled, labelVisibility);
		p["min"] = numJ(minValue);
		p["max"] = numJ(maxValue);
		p["step"] = numJ(st_);
		p["format"] = format;
		p["isInt"] = isIntegral!T;
		p["range"] = true;
		return widget!(T[2])("slider", id, key, value, (T[2] v) => toJ(v[]), (Json j) {
			T[2] r = [jNum!T(j[0]), jNum!T(j[1])];
			if (r[0] > r[1]) { auto t = r[0]; r[0] = r[1]; r[1] = t; }
			return r;
		}, onChange, p);
	}

	/// `st.number_input` (double)
	double numberInput(string label, double value = 0, double minValue = -double.infinity,
		double maxValue = double.infinity, double step = 0.01, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string format = null,
		string placeholder = null, string labelVisibility = "visible")
	{
		return numberInputImpl!double(label, value, minValue, maxValue, step, key, help, onChange, disabled,
			format, placeholder, labelVisibility);
	}

	/// `st.number_input` (int) — chosen when `value` is an int.
	int numberInput(string label, int value, double minValue = -double.infinity,
		double maxValue = double.infinity, int step = 1, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string format = null,
		string placeholder = null, string labelVisibility = "visible")
	{
		return numberInputImpl!int(label, value, minValue, maxValue, step, key, help, onChange, disabled,
			format, placeholder, labelVisibility);
	}

	private T numberInputImpl(T)(string label, T value, double minValue = -double.infinity,
		double maxValue = double.infinity, T step = T.init, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string format = null,
		string placeholder = null, string labelVisibility = "visible") if (isNumeric!T)
	{
		static if (isIntegral!T)
		{
			T st_ = step == T.init ? 1 : step;
			T def = value;
		}
		else
		{
			T st_ = (step != step || step == 0) ? cast(T) 0.01 : step;
			T def = value != value ? cast(T) 0 : value;
		}
		if (def < minValue && !isInfinity(minValue)) def = cast(T) minValue;
		auto id = widgetId("number_input", key, label, minValue.to!string, maxValue.to!string);
		auto p = commonProps(label, help, disabled, labelVisibility);
		p["min"] = toJ(minValue);
		p["max"] = toJ(maxValue);
		p["step"] = numJ(st_);
		p["isInt"] = isIntegral!T;
		p["format"] = format;
		p["placeholder"] = placeholder;
		return widget!T("number_input", id, key, def, (T v) => numJ(v), (Json j) {
			auto v = jNum!T(j);
			if (v < minValue) v = cast(T) minValue;
			if (v > maxValue) v = cast(T) maxValue;
			return v;
		}, onChange, p);
	}

	/// `st.text_input`. `type` may be "default" or "password".
	string textInput(string label, string value = "", size_t maxChars = 0, string key = null,
		string type = "default", string help = null, void delegate() onChange = null,
		string placeholder = null, bool disabled = false, string labelVisibility = "visible")
	{
		auto id = widgetId("text_input", key, label, maxChars.to!string, type);
		auto p = commonProps(label, help, disabled, labelVisibility);
		p["maxChars"] = maxChars;
		p["type"] = type;
		p["placeholder"] = placeholder;
		return widget!string("text_input", id, key, value, (string v) => Json(v),
			(Json j) => limitChars(j.type == Json.Type.null_ ? "" : j.get!string, maxChars), onChange, p);
	}

	/// `st.text_area`
	string textArea(string label, string value = "", int height = 0, size_t maxChars = 0, string key = null,
		string help = null, void delegate() onChange = null, string placeholder = null, bool disabled = false,
		string labelVisibility = "visible")
	{
		auto id = widgetId("text_area", key, label, maxChars.to!string);
		auto p = commonProps(label, help, disabled, labelVisibility);
		p["maxChars"] = maxChars;
		p["height"] = height;
		p["placeholder"] = placeholder;
		return widget!string("text_area", id, key, value, (string v) => Json(v),
			(Json j) => limitChars(j.type == Json.Type.null_ ? "" : j.get!string, maxChars), onChange, p);
	}

	/// `st.date_input` (defaults to today).
	Date dateInput(string label, Date value = Date.init, Date minValue = Date.init, Date maxValue = Date.init,
		string key = null, string help = null, void delegate() onChange = null, bool disabled = false,
		string labelVisibility = "visible")
	{
		if (value == Date.init)
			value = cast(Date) Clock.currTime();
		auto id = widgetId("date_input", key, label);
		auto p = commonProps(label, help, disabled, labelVisibility);
		p["min"] = minValue == Date.init ? null : dateStr(minValue);
		p["max"] = maxValue == Date.init ? null : dateStr(maxValue);
		return widget!Date("date_input", id, key, value, (Date d) => Json(dateStr(d)), (Json j) {
			auto d = strDate(j.get!string);
			if (minValue != Date.init && d < minValue) d = minValue;
			if (maxValue != Date.init && d > maxValue) d = maxValue;
			return d;
		}, onChange, p);
	}

	/// A date range: two clicks in the calendar (or typing "2026-01-01 – 2026-01-31") pick the start
	/// and the end (Streamlit: `st.date_input` with a pair). Defaults to today–today; the result
	/// always has `start <= end` and stays within `minValue`/`maxValue`.
	DateRange dateRangeInput(string label, DateRange value = DateRange.init, Date minValue = Date.init,
		Date maxValue = Date.init, string key = null, string help = null, void delegate() onChange = null,
		bool disabled = false, string labelVisibility = "visible")
	{
		if (value == DateRange.init)
		{
			auto today = cast(Date) Clock.currTime();
			value = DateRange(today, today);
		}
		DateRange fix(DateRange r)
		{
			if (r.end < r.start)
				r = DateRange(r.end, r.start);
			foreach (d; [&r.start, &r.end])
			{
				if (minValue != Date.init && *d < minValue) *d = minValue;
				if (maxValue != Date.init && *d > maxValue) *d = maxValue;
			}
			return r;
		}
		auto id = widgetId("date_range_input", key, label);
		auto p = commonProps(label, help, disabled, labelVisibility);
		p["min"] = minValue == Date.init ? null : dateStr(minValue);
		p["max"] = maxValue == Date.init ? null : dateStr(maxValue);
		// fix() also on the way out: a value set through st.session[key] skips the decoder
		return fix(widget!DateRange("date_range_input", id, key, fix(value),
			(DateRange r) { r = fix(r); return Json([Json(dateStr(r.start)), Json(dateStr(r.end))]); },
			(Json j) {
				if (j.type != Json.Type.array || j.length != 2)
					throw new StreamlitAPIException("a date range is [start, end]");
				return fix(DateRange(strDate(j[0].get!string), strDate(j[1].get!string)));
			}, onChange, p));
	}

	/// Free-text tags (streamlitd only): typed text becomes a chip on Enter or comma; `suggestions`
	/// are offered while typing. Tags are trimmed, empty and repeated ones dropped, and at most
	/// `maxTags` kept (0 = no limit).
	string[] tagsInput(string label, string[] value = null, string[] suggestions = null, size_t maxTags = 0,
		string key = null, string help = null, void delegate() onChange = null, bool disabled = false,
		string placeholder = null, string labelVisibility = "visible")
	{
		import std.string : strip;
		string[] norm(string[] a)
		{
			string[] r;
			foreach (t; a)
			{
				auto s = t.strip;
				bool seen;
				foreach (x; r)
					seen = seen || x == s;
				if (s.length && !seen && (maxTags == 0 || r.length < maxTags))
					r ~= s;
			}
			return r;
		}
		auto id = widgetId("tags_input", key, label);
		auto p = commonProps(label, help, disabled, labelVisibility);
		p["suggestions"] = toJ(suggestions);
		p["maxTags"] = maxTags;
		p["placeholder"] = placeholder;
		return norm(widget!(string[])("tags_input", id, key, norm(value), (string[] v) => toJ(norm(v)), (Json j) {
			string[] r;
			foreach (e; j)
				r ~= e.get!string;
			return norm(r);
		}, onChange, p));
	}

	/// Pick nodes of a tree in a searchable pop-up (streamlitd only). Returns the ids of the picked
	/// nodes in tree order. With `multi`, checking a node checks its whole subtree (also a parent id
	/// in `value`), and a node is included when all of its children are; without it, one node.
	/// Ids that are not in the tree are dropped.
	string[] treeSelect(string label, TreeNode[] nodes, string[] value = null, bool multi = true, string key = null,
		string help = null, void delegate() onChange = null, bool disabled = false, string placeholder = null,
		string labelVisibility = "visible")
	{
		bool[string] ids;
		collectTreeIds(nodes, ids); // throws on duplicate ids
		string[] keep(string[] a) { return normalizeTree(nodes, a, multi); }
		auto tree = treeJson(nodes);
		auto id = widgetId("tree_select", key, label, tree.toString, multi ? "m" : "s");
		auto p = commonProps(label, help, disabled, labelVisibility);
		p["nodes"] = tree;
		p["multi"] = multi;
		p["placeholder"] = placeholder;
		return keep(widget!(string[])("tree_select", id, key, keep(value), (string[] v) => toJ(keep(v)), (Json j) {
			string[] r;
			foreach (e; j)
				r ~= e.get!string;
			return keep(r);
		}, onChange, p));
	}

	/// A button that copies `text` to the clipboard (streamlitd only); it does not rerun the app.
	/// With `url`, a path such as "/auth/reset?token=..." is copied as a full URL of this app
	/// (the browser adds the address it is on).
	void copyButton(string text, string label = "Copy", string icon = "📋", string help = null, bool url = false)
	{
		emit(jo("kind", "copy_button", "text", text, "label", label, "icon", icon, "help", help, "url", url));
	}

	/// `st.time_input`
	TimeOfDay timeInput(string label, TimeOfDay value = TimeOfDay.init, string key = null,
		string help = null, void delegate() onChange = null, bool disabled = false, int stepSeconds = 900,
		string labelVisibility = "visible")
	{
		auto id = widgetId("time_input", key, label);
		auto p = commonProps(label, help, disabled, labelVisibility);
		p["step"] = stepSeconds;
		return widget!TimeOfDay("time_input", id, key, value, (TimeOfDay t) => Json(timeStr(t)),
			(Json j) => strTime(j.get!string), onChange, p);
	}

	/// `st.color_picker`
	string colorPicker(string label, string value = "#000000", string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string labelVisibility = "visible")
	{
		auto id = widgetId("color_picker", key, label);
		return widget!string("color_picker", id, key, value, (string v) => Json(v), (Json j) => j.get!string,
			onChange, commonProps(label, help, disabled, labelVisibility));
	}

	private ptrdiff_t choiceIndex(string kind, string label, string[] labels, ptrdiff_t index, string key,
		string help, void delegate() onChange, bool disabled, string labelVisibility, Json extra)
	{
		auto id = widgetId(kind, key, [label] ~ labels);
		auto p = commonProps(label, help, disabled, labelVisibility);
		p["options"] = toJ(labels);
		p["multi"] = false;
		foreach (string k, v; extra)
			p[k] = v;
		auto n = cast(ptrdiff_t) labels.length;
		ptrdiff_t def = (index >= 0 && index < n) ? index : -1;
		return widget!ptrdiff_t(kind, id, key, def,
			(ptrdiff_t i) => i < 0 ? Json(null) : Json(cast(long) i),
			(Json j) {
				if (j.type == Json.Type.null_) return cast(ptrdiff_t) -1;
				auto i = jNum!ptrdiff_t(j);
				if (i < 0 || i >= n) throw new Exception("index out of range");
				return i;
			}, onChange, p);
	}

	private long[] choiceIndices(string kind, string label, string[] labels, long[] def, string key, string help,
		void delegate() onChange, bool disabled, string labelVisibility)
	{
		auto id = widgetId(kind, key, [label, "multi"] ~ labels);
		auto p = commonProps(label, help, disabled, labelVisibility);
		p["options"] = toJ(labels);
		p["multi"] = true;
		auto n = labels.length;
		return widget!(long[])(kind, id, key, def, (long[] v) => toJ(v), (Json j) {
			long[] r;
			foreach (e; j)
			{
				auto i = jNum!long(e);
				if (i < 0 || i >= n) throw new Exception("index out of range");
				r ~= i;
			}
			return r;
		}, onChange, p);
	}

	private static long[] indicesOf(string[] options, string[] values)
	{
		long[] r;
		foreach (v; values)
			foreach (i, o; options)
				if (o == v)
				{
					r ~= i;
					break;
				}
		return r;
	}

	/// `st.pills` (single selection). Returns `null` when nothing is selected.
	string pills(string label, string[] options, ptrdiff_t index = -1, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string labelVisibility = "visible")
	{
		auto i = choiceIndex("pills", label, options, index, key, help, onChange, disabled, labelVisibility,
			Json.emptyObject);
		return i < 0 ? null : options[i];
	}

	/// `st.pills` over any option type (returns `T.init` when nothing is selected).
	T pillsOf(T)(string label, T[] options, ptrdiff_t index = -1, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string delegate(T) formatFunc = null,
		string labelVisibility = "visible")
	{
		auto i = choiceIndex("pills", label, formatOptions(options, formatFunc), index, key, help, onChange,
			disabled, labelVisibility, Json.emptyObject);
		return i < 0 ? T.init : options[i];
	}

	/// `st.pills(selection_mode="multi")`
	string[] pillsMulti(string label, string[] options, string[] default_ = null, string key = null,
		string help = null, void delegate() onChange = null, bool disabled = false, string labelVisibility = "visible")
	{
		string[] r;
		foreach (i; choiceIndices("pills", label, options, indicesOf(options, default_), key, help, onChange,
				disabled, labelVisibility))
			r ~= options[i];
		return r;
	}

	/// `st.segmented_control` (single selection). Returns `null` when nothing is selected.
	string segmentedControl(string label, string[] options, ptrdiff_t index = -1, string key = null,
		string help = null, void delegate() onChange = null, bool disabled = false, string labelVisibility = "visible")
	{
		auto i = choiceIndex("segmented_control", label, options, index, key, help, onChange, disabled,
			labelVisibility, Json.emptyObject);
		return i < 0 ? null : options[i];
	}

	/// `st.segmented_control` over any option type (returns `T.init` when nothing is selected).
	T segmentedControlOf(T)(string label, T[] options, ptrdiff_t index = -1, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string delegate(T) formatFunc = null,
		string labelVisibility = "visible")
	{
		auto i = choiceIndex("segmented_control", label, formatOptions(options, formatFunc), index, key, help,
			onChange, disabled, labelVisibility, Json.emptyObject);
		return i < 0 ? T.init : options[i];
	}

	/// `st.segmented_control(selection_mode="multi")`
	string[] segmentedControlMulti(string label, string[] options, string[] default_ = null, string key = null,
		string help = null, void delegate() onChange = null, bool disabled = false, string labelVisibility = "visible")
	{
		string[] r;
		foreach (i; choiceIndices("segmented_control", label, options, indicesOf(options, default_), key, help,
				onChange, disabled, labelVisibility))
			r ~= options[i];
		return r;
	}

	/// `st.feedback`: "thumbs" (0 = down, 1 = up), "faces" (0..4) or "stars" (0..4).
	/// Returns -1 when nothing is selected.
	ptrdiff_t feedback(string type = "thumbs", string key = null, void delegate() onChange = null,
		bool disabled = false)
	{
		import streamlitd.errors : StreamlitAPIException;
		string[] opts;
		switch (type)
		{
			case "thumbs": opts = ["👎", "👍"]; break;
			case "faces": opts = ["😞", "🙁", "😐", "🙂", "😀"]; break;
			case "stars": opts = ["★", "★", "★", "★", "★"]; break;
			default: throw new StreamlitAPIException(`feedback type must be "thumbs", "faces" or "stars"`);
		}
		return choiceIndex("feedback", "", opts, -1, key, null, onChange, disabled, "collapsed",
			jo("feedbackType", type));
	}

	/// `st.chat_input` — returns the submitted message, or `null` if nothing was submitted this run.
	/// When called on the main area it is pinned to the bottom of the page.
	string chatInput(string placeholder = "Your message", string key = null, size_t maxChars = 0,
		bool disabled = false, void delegate() onSubmit = null)
	{
		auto target = (path == [0]) ? new St(sess, [2]) : this;
		auto id = widgetId("chat_input", key, placeholder);
		auto p = jo("placeholder", placeholder, "maxChars", maxChars, "disabled", disabled);
		return target.widget!string("chat_input", id, key, null, (string v) => Json(v),
			(Json j) => j.type == Json.Type.string ? j.get!string : null, onSubmit, p, true);
	}
}
