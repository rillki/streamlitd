/// A helpdesk built with streamlitd: tickets and customers shared by all agents, with live
/// updates, roles, dialogs, a JSON API and exports. See docs/examples.md.
import std.algorithm : count;
import std.conv : to;
import streamlitd;
import helpdesk.store;
import helpdesk.pages.dashboard;
import helpdesk.pages.tickets;
import helpdesk.pages.customers;
import helpdesk.pages.admin;
import helpdesk.api : routes;

void app(St st)
{
	st.setPageConfig(title: "Helpdesk", icon: "🎧", layout: Layout.wide);
	auto ts = store.tickets;
	auto t0 = now;
	auto open = ts.count!(t => t.isOpen);
	auto overdue = ts.count!(t => t.overdue(t0));
	Page[] pages = [
		Page(&dashboard, "Dashboard", "📊", badge: overdue ? overdue.to!string : null),
		Page(&tickets, "Tickets", "🎫", section: "Support", badge: open ? open.to!string : null),
		Page(&customers, "Customers", "🏢", section: "Support"),
	];
	if (st.user.isAdmin)
		pages ~= Page(&admin, "Users", "👥", section: "Settings");
	auto page = st.navigation(pages, sections: "collapsible");
	st.userMenu(["Help"]);
	page.run(st);
}

mixin StreamlitMain!(app, routes);
