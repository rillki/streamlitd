/// A project planner built with streamlitd: a Gantt chart of phases and tasks with milestones,
/// dependencies and progress, edited in dialogs, and a table view. See docs/examples.md.
import std.algorithm : count;
import std.conv : to;
import streamlitd;
import gantt.store;
import gantt.pages.timeline;
import gantt.pages.table;

void app(St st)
{
	st.setPageConfig(title: "Project plan", icon: "📅", layout: Layout.wide);
	auto d = today;
	auto late = store.tasks.count!(t => t.late(d));
	auto page = st.navigation([
		Page(&timelinePage, "Timeline", "📅"),
		Page(&tablePage, "Tasks", "📋", badge: late ? late.to!string : null),
	]);
	page.run(st);
}

mixin StreamlitMain!(app);
