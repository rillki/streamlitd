/// Multipage app: top navigation with a section, header bar items, a banner and a footer;
/// chat and query params.
import streamlitd;
import std.conv : to;
import std.uni : toUpper;

void home(St st)
{
	st.title("🏠 Home");
	st.write("This is a multipage **streamlitd** app. Use the navigation bar at the top to switch pages;" ~
		" the **Reports** pages are in a dropdown.");
	st.pageLink("chat", "Go to the chat page", "💬");
	if (st.button("Switch to settings"))
		st.switchPage("Settings");
}

void chat(St st)
{
	st.title("💬 Echo bot");
	auto history = st.session.get!(string[][])("history");
	foreach (m; history)
		st.chatMessage(m[0]).markdown(m[1]);
	if (auto prompt = st.chatInput("Say something"))
	{
		st.chatMessage("user").markdown(prompt);
		auto reply = "You said: **" ~ prompt.toUpper ~ "**";
		st.chatMessage("assistant").markdown(reply);
		history ~= ["user", prompt];
		history ~= ["assistant", reply];
		st.session["history"] = history;
	}
	if (history.length && st.sidebar.button("Clear chat"))
	{
		st.session.remove("history");
		st.rerun();
	}
}

void settings(St st)
{
	st.title("⚙️ Settings");
	auto q = st.queryParams;
	auto theme = st.radio("Theme", ["light", "dark"], q.get("theme", "light") == "dark" ? 1 : 0);
	if (q["theme"] != theme)
		q["theme"] = theme;
	st.write("Query param theme =", q.get("theme", "(none)"));
}

void report(string what)(St st)
{
	import std.algorithm : min;
	import std.format : format;
	st.breadcrumbs();                         // Home › Reports › <page>, from st.navigation
	st.title("📈 " ~ what);
	st.write("The " ~ what ~ " report. This page is in the **Reports** section of the navigation.");
	auto action = st.menuButton("Export", ["CSV", "Excel", "-", "Print"], icon: "⬇️", key: "export-" ~ what);
	if (action.length)
		st.toast("Exported " ~ what ~ " as " ~ action);
	string[] rows;
	foreach (i; 1 .. 48)
		rows ~= format("%s item %02d", what, i);
	auto page = st.pagination(rows.length, 10, key: "page-" ~ what);
	foreach (r; rows[(page - 1) * 10 .. min(page * 10, rows.length)])
		st.text(r);
}

void app(St st)
{
	st.setPageConfig(title: "Multipage demo"); // no icon: the tab shows the current page's icon
	auto page = st.navigation([
		Page(&home, "Home", "🏠"),
		Page(&chat, "Chat", "💬"),
		Page(&report!"Sales", "Sales", "💰", section: "Reports"),
		Page(&report!"Inventory", "Inventory", "📦", section: "Reports"),
		Page(&settings, "Settings", "⚙️"),
	], position: "top");
	st.banner("**Demo data**: everything here resets when the server restarts.", "info");
	if (st.topbar.button("Help", key: "help"))
		st.toast("Pages are in the bar at the top; on a phone, open the menu with the page title.");
	page.run(st);
	st.footer.caption("streamlitd multipage demo · version 1.0");
}

mixin StreamlitMain!app;
