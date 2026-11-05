/// Multipage apps: `st.navigation`, `Page`, `st.switchPage`, `st.pageLink`.
module streamlitd.pages;

import std.functional : toDelegate;
import std.traits : isCallable;
import vibe.data.json;

import streamlitd.delta : St;
import streamlitd.session : AppFn;
import streamlitd.util;

/// A page of a multipage app.
struct Page
{
	AppFn fn;
	string title;
	string icon;
	string urlPath;   /// defaults to a slug of the title
	bool isDefault;

	this(void function(St) fn, string title, string icon = null, string urlPath = null, bool isDefault = false)
	{
		this(toDelegate(fn), title, icon, urlPath, isDefault);
	}

	this(AppFn fn, string title, string icon = null, string urlPath = null, bool isDefault = false)
	{
		this.fn = fn;
		this.title = title;
		this.icon = icon;
		this.urlPath = urlPath;
		this.isDefault = isDefault;
	}

	/// Run the page's function.
	void run(St st) { fn(st); }
}

/// URL slug of a title.
string slugify(string title)
{
	import std.uni : toLower, isAlphaNum;
	string r;
	bool dash;
	foreach (dchar c; title.toLower)
	{
		if (isAlphaNum(c))
		{
			import std.conv : to;
			r ~= c.to!string;
			dash = false;
		}
		else if (!dash && r.length)
		{
			r ~= "-";
			dash = true;
		}
	}
	while (r.length && r[$ - 1] == '-')
		r = r[0 .. $ - 1];
	return r;
}

/// Page elements mixed into `St`.
mixin template PageElements()
{

	/// `st.navigation` — declares the pages and returns the selected one; call `.run(st)` on it.
	/// `position`: "sidebar" or "hidden".
	Page navigation(Page[] pages, string position = "sidebar")
	{
		if (pages.length == 0)
			throw new StreamlitAPIException("navigation() needs at least one page");
		size_t def = 0;
		foreach (i, ref p; pages)
		{
			if (p.urlPath.length == 0)
				p.urlPath = slugify(p.title);
			if (p.isDefault)
				def = i;
		}
		size_t sel = def;
		foreach (i, p; pages)
			if (p.urlPath == sess.pagePath && sess.pagePath.length)
				sel = i;
		sess.navPagePaths = null;
		auto list = Json.emptyArray;
		foreach (i, p; pages)
		{
			sess.navPagePaths ~= p.urlPath;
			list ~= jo("title", p.title, "icon", p.icon, "urlPath", i == def ? "" : p.urlPath);
		}
		sess.send(jo("type", "navigation", "pages", list, "current", sel == def ? "" : pages[sel].urlPath,
			"position", position, "title", pages[sel].title));
		return pages[sel];
	}

	/// `st.switch_page` — switch to another page (by url path or title) and rerun.
	void switchPage(string page)
	{
		auto target = slugify(page);
		foreach (p; sess.navPagePaths)
			if (p == page)
				target = p;
		sess.pagePath = target;
		sess.send(jo("type", "set_page", "urlPath", target));
		rerun();
	}

	/// `st.page_link`
	void pageLink(string urlPath, string label, string icon = null)
	{
		emit(jo("kind", "page_link", "urlPath", urlPath, "label", label, "icon", icon));
	}
}

unittest
{
	assert(slugify("Sales Dashboard!") == "sales-dashboard");
	assert(slugify("  Hello  World ") == "hello-world");
}
