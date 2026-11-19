/// A live operations monitor built with streamlitd: a background producer samples services and
/// pushes to every open page; alerts with rules; a slow legacy source off the event loop.
/// See docs/examples.md.
import std.conv : to;
import streamlitd;
import monitor.metrics;
import monitor.pages.overview;
import monitor.pages.services;
import monitor.pages.alerts;

void app(St st)
{
	st.setPageConfig(title: "Monitor", icon: "📈", layout: Layout.wide);
	auto open = metrics.unacked;
	auto page = st.navigation([
		Page(&overview, "Overview", "📈"),
		Page(&servicesPage, "Services", "🖥️"),
		Page(&alertsPage, "Alerts", "🔔", badge: open ? open.to!string : null),
	]);
	// the navigation is drawn by full runs only: when the alert count changes, rerun the app so
	// the badge follows (this fragment draws nothing)
	st.sidebar.fragment((St f) {
		if (metrics.unacked != open)
			st.rerun();
	}, refreshOn: alertsTopic, key: "alert-badge");
	page.run(st);
}

mixin StreamlitMain!(app);
