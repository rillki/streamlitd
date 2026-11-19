/// Purchase planning with streamlitd: a yearly plan edited in a table, plan vs fact as a tree,
/// deliveries on a calendar, a CSV import wizard. Data is shared by all users. See docs/examples.md.
import std.algorithm : count;
import std.conv : to;
import streamlitd;
import planning.store;
import planning.pages.plan;
import planning.pages.actuals;
import planning.pages.deliveries;
import planning.pages.imports;

void app(St st)
{
	st.setPageConfig(title: "Purchase planning", icon: "📦", layout: Layout.wide);
	auto t = today;
	auto late = store.deliveries.count!(d => !d.delivered && d.date < t);
	auto page = st.navigation([
		Page(&planPage, "Plan", "🗓️", section: "Planning"),
		Page(&actualsPage, "Plan vs fact", "📊", section: "Planning"),
		Page(&deliveriesPage, "Deliveries", "🚚", section: "Planning", badge: late ? late.to!string : null),
		Page(&importPage, "Import", "📥", section: "Data"),
	]);
	page.run(st);
}

mixin StreamlitMain!(app);
