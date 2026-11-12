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
	/// Group heading in the navigation: a heading in the sidebar, a dropdown in the top bar
	/// (Streamlit's `st.navigation({"Section": [...]})`). Pages of a section should be adjacent.
	string section;

	this(void function(St) fn, string title, string icon = null, string urlPath = null, bool isDefault = false,
		string section = null)
	{
		this(toDelegate(fn), title, icon, urlPath, isDefault, section);
	}

	this(AppFn fn, string title, string icon = null, string urlPath = null, bool isDefault = false,
		string section = null)
	{
		this.fn = fn;
		this.title = title;
		this.icon = icon;
		this.urlPath = urlPath;
		this.isDefault = isDefault;
		this.section = section;
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
	/// `position`: "sidebar", "top" (links in the header bar; sections become dropdowns, and on
	/// narrow screens everything moves into a ☰ menu) or "hidden". Group pages with `Page.section`.
	Page navigation(Page[] pages, string position = "sidebar")
	{
		if (pages.length == 0)
			throw new StreamlitAPIException("navigation() needs at least one page");
		if (position != "sidebar" && position != "top" && position != "hidden")
			throw new StreamlitAPIException(`navigation() position must be "sidebar", "top" or "hidden", not "` ~ position ~ `"`);
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
			list ~= jo("title", p.title, "icon", p.icon, "urlPath", i == def ? "" : p.urlPath, "section", p.section);
		}
		// breadcrumbs: default page › section › current page
		auto crumbs = Json.emptyArray;
		if (sel != def)
			crumbs ~= jo("label", pages[def].title, "urlPath", "");
		if (pages[sel].section.length)
			crumbs ~= jo("label", pages[sel].section);
		crumbs ~= jo("label", pages[sel].title, "urlPath", sel == def ? "" : pages[sel].urlPath);
		sess.navCrumbs = crumbs;
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

	/// Breadcrumbs for the current page, from `st.navigation`: the default page › the page's
	/// section › the page (streamlitd only). Call it after `st.navigation`, e.g. at the top of a page.
	void breadcrumbs()
	{
		if (sess.navCrumbs.type != Json.Type.array)
			throw new StreamlitAPIException("breadcrumbs() without arguments needs st.navigation() first; " ~
				"or pass the trail: breadcrumbs([\"Reports\", \"Q3\"], [\"reports\", null])");
		emit(jo("kind", "breadcrumbs", "items", sess.navCrumbs));
	}

	/// Breadcrumbs with an explicit trail (streamlitd only). `urlPaths[i]` makes item i a link to
	/// that app page (null or missing: plain text); the last item is the current position.
	void breadcrumbs(string[] labels, string[] urlPaths = null)
	{
		if (urlPaths.length > labels.length)
			throw new StreamlitAPIException("breadcrumbs(): more urlPaths than labels");
		auto items = Json.emptyArray;
		foreach (i, l; labels)
			items ~= jo("label", l, "urlPath", i < urlPaths.length ? urlPaths[i] : null);
		emit(jo("kind", "breadcrumbs", "items", items));
	}

	/// The user menu in the header bar: the logged-in user's picture (or initials) and name, opening
	/// a menu with `items` and "Log out". Returns the item clicked in this run, otherwise null.
	/// Signed out, it shows a "Log in" button; without `[auth]` configured it shows nothing.
	/// It is always placed in `st.topbar`, wherever it is called.
	string userMenu(string[] items = null, bool logout = true, string key = null)
	{
		import std.array : join;
		auto u = user;
		auto tb = topbar;
		auto id = tb.widgetId("user_menu", key, items.join("\x01"));
		auto shown = u.name.length ? u.name : u.email.length ? u.email : u.sub;
		auto p = jo("items", items, "auth", sess.authEnabled, "logout", logout && sess.authEnabled,
			"loggedIn", u.isLoggedIn, "name", shown, "email", u.email);
		if (u.isLoggedIn && sess.user["picture"].type == Json.Type.string)
			p["picture"] = sess.user["picture"];
		return tb.widget!string("user_menu", id, key, null, (string v) => Json(v), (Json j) {
			auto s = j.get!string;
			foreach (it; items)
				if (it == s)
					return s;
			throw new StreamlitAPIException("not a menu item");
		}, null, p, true);
	}
}

unittest
{
	assert(slugify("Sales Dashboard!") == "sales-dashboard");
	assert(slugify("  Hello  World ") == "hello-world");
}
