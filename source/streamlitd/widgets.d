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
