/// A TODO app built with streamlitd: everyone signs up and gets their own lists; tasks with due
/// dates, priorities and tags; quick add, filters, bulk actions, edit dialogs. See docs/examples.md.
import std.algorithm : count, filter;
import std.conv : to;
import streamlitd;
import todo.store;
import todo.ui;
import todo.pages.tasks;
import todo.pages.lists;

void app(St st)
{
	st.setPageConfig(title: "Tasks", icon: "✅");
	auto user = me(st);
	auto b = store.board(user);
	auto t = today;
	string badge(size_t n) { return n ? n.to!string : null; }
	auto dueToday = b.tasks.count!(x => !x.done && x.due.length && x.dueDate <= t);
	Page[] pages = [
		Page((St s) { taskView(s, "today", "Today"); }, "Today", "☀️", "today", true, section: "Views", badge: badge(dueToday)),
		Page((St s) { taskView(s, "upcoming", "Upcoming"); }, "Upcoming", "🗓️", "upcoming", section: "Views"),
	];
	foreach (l; b.lists)
		pages ~= listPage(l, b.tasks.count!(x => x.list == l.id && !x.done));
	pages ~= Page(&listsPage, "Manage lists", "⚙️", "lists", section: "Settings");
	auto page = st.navigation(pages);
	st.userMenu();
	page.run(st);
}

// a function, so each page gets its own list (closures in a foreach share the loop variable)
Page listPage(TaskList l, size_t open)
{
	return Page((St s) { taskView(s, l.id, escapeMarkdown(l.icon ~ " " ~ l.name)); }, l.name, l.icon, "list-" ~ l.id,
		section: "Lists", badge: open ? open.to!string : null);
}

mixin StreamlitMain!(app);
