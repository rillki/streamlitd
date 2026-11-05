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
	void metric(string label, string value, string delta = null, string deltaColor = "normal",
		string help = null, bool border = false)
	{
		emit(jo("kind", "metric", "label", label, "value", value, "delta", delta, "deltaColor", deltaColor,
			"help", help, "border", border));
	}

	/// ditto
	void metric(string label, long value, string delta = null, string deltaColor = "normal",
		string help = null, bool border = false)
	{
		metric(label, value.to!string, delta, deltaColor, help, border);
	}

	/// ditto
	void metric(string label, double value, string delta = null, string deltaColor = "normal",
		string help = null, bool border = false)
	{
		metric(label, format("%g", value), delta, deltaColor, help, border);
	}

	/// `st.json`
	void json(T)(T value, bool expanded = true)
	{
		static if (isSomeString!T)
		{
			Json j;
			try
				j = parseJsonString(value);
			catch (Exception)
				j = Json(value);
			emit(jo("kind", "json", "value", j, "expanded", expanded));
		}
		else
			emit(jo("kind", "json", "value", toJ(value), "expanded", expanded));
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
				json(a);
			}
			else
				pending ~= (pending.length ? " " : "") ~ a.to!string;
		}
		flush();
	}
}
