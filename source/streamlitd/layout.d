/// Layout containers.
module streamlitd.layout;

/// Layout elements mixed into `St`.
mixin template LayoutElements()
{

	/// `st.sidebar`
	@property St sidebar()
	{
		auto s = new St(sess, [cast(int) RootContainer.sidebar]);
		return s;
	}

	/// `st.topbar`: the right side of the header bar, for small items such as buttons,
	/// `menuButton` or `userMenu` (streamlitd only).
	@property St topbar()
	{
		return new St(sess, [cast(int) RootContainer.topbar]);
	}

	/// `st.footer`: the area under the main content, on every page (streamlitd only).
	@property St footer()
	{
		return new St(sess, [cast(int) RootContainer.footer]);
	}

	/// A card (streamlitd only): a framed box with an optional image (URL) or icon, a title and a
	/// subtitle. Returns its body; put text, metrics and buttons in it. Use `st.columns` for a grid.
	/// With `link` (an app page's URL path, or an http(s) URL) the whole card is a link; buttons in
	/// it still work.
	St card(string title = null, string subtitle = null, string image = null, string icon = null, string key = null,
		string link = null)
	{
		return emitBlock("card", jo("title", title, "subtitle", subtitle, "image", image, "icon", icon, "key", key,
			"link", link));
	}

	/// `st.container`. `height` > 0 makes it scrollable.
	St container(bool border = false, int height = 0, string key = null)
	{
		return emitBlock("vertical", jo("border", border, "height", height, "key", key));
	}

	/// `st.container` with a body.
	void container(scope void delegate(St) body_, bool border = false, int height = 0)
	{
		body_(container(border, height));
	}

	/// `st.columns(n)`
	St[] columns(size_t n, string gap = "small", string verticalAlignment = "top", bool border = false)
	{
		auto w = new double[n];
		w[] = 1.0;
		return columns(w, gap, verticalAlignment, border);
	}

	/// `st.columns([2, 1, 1])` — relative widths.
	St[] columns(double[] spec, string gap = "small", string verticalAlignment = "top", bool border = false)
	{
		if (spec.length == 0)
			throw new StreamlitAPIException("columns() needs at least one column");
		double total = 0;
		foreach (w; spec)
			total += w;
		auto row = emitBlock("horizontal", jo("gap", gap, "align", verticalAlignment));
		St[] cols;
		foreach (w; spec)
			cols ~= row.emitBlock("column", jo("weight", w / total, "border", border));
		return cols;
	}

	/// `st.expander`
	St expander(string label, bool expanded = false, string icon = null)
	{
		return emitBlock("expander", jo("label", label, "expanded", expanded, "icon", icon));
	}

	/// `st.expander` with a body.
	void expander(string label, scope void delegate(St) body_, bool expanded = false)
	{
		body_(expander(label, expanded));
	}

	/// `st.popover`
	St popover(string label, string help = null, bool disabled = false, bool useContainerWidth = false)
	{
		return emitBlock("popover", jo("label", label, "help", help, "disabled", disabled,
			"fullWidth", useContainerWidth));
	}

	/// `st.tabs`
	St[] tabs(string[] labels)
	{
		if (labels.length == 0)
			throw new StreamlitAPIException("tabs() needs at least one label");
		auto t = emitBlock("tabs", jo("labels", labels));
		St[] r;
		foreach (l; labels)
			r ~= t.emitBlock("tab", jo("label", l));
		return r;
	}

	/// `st.form` — widgets inside only send their values when the submit button is pressed.
	St form(string key, bool clearOnSubmit = false, bool border = true, bool enterToSubmit = true)
	{
		if (formId.length)
			throw new StreamlitAPIException("Forms cannot be nested.");
		auto f = emitBlock("form", jo("formId", key, "border", border, "clearOnSubmit", clearOnSubmit,
			"enterToSubmit", enterToSubmit));
		f.formId = key;
		f.formClear = clearOnSubmit ? key : null;
		return f;
	}

	/// `st.form` with a body.
	void form(string key, scope void delegate(St) body_, bool clearOnSubmit = false, bool border = true)
	{
		body_(form(key, clearOnSubmit, border));
	}

	/// `st.empty` — a single-element placeholder. Every call on the returned
	/// generator replaces its content.
	St empty()
	{
		auto p = emit(jo("kind", "empty"));
		auto s = new St(sess, p, true, formId);
		s.formClear = formClear;
		s.fragmentId = fragmentId;
		return s;
	}

	/// `st.chat_message` — a chat bubble container. `name` "user"/"assistant" pick default avatars.
	St chatMessage(string name, string avatar = null)
	{
		return emitBlock("chat_message", jo("name", name, "avatar", avatar));
	}

	/// `st.chat_message` with a body.
	void chatMessage(string name, scope void delegate(St) body_, string avatar = null)
	{
		body_(chatMessage(name, avatar));
	}
}
