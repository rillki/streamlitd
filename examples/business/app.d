/// A business dashboard in the style of a purchasing department's app: KPI tiles with trends,
/// configured and tree tables, a notification inbox, exports built on click, and the request
/// context. Sidebar sections fold; pages carry badges.
import streamlitd;
import std.algorithm : filter, map, sum;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.datetime : Date;

alias C = ColumnConfig;

/// Purchases per manager, supplier and brand (stands in for a database query).
DataFrame purchases()
{
	return new DataFrame()
		.addColumn("manager", ["Ann", "Ann", "Ann", "Ann", "Bob", "Bob", "Bob"])
		.addColumn("supplier", ["ACME", "ACME", "Globex", "Globex", "Initech", "Initech", "Umbrella"])
		.addColumn("brand", ["Rocket", "Anvil", "Gizmo", "Widget", "Stapler", "Printer", "Shield"])
		.addColumn("plan", [1_500.0, 800.0, 1_000.0, 400.0, 300.0, 1_400.0, 900.0])
		.addColumn("fact", [1_200.0, 650.0, 980.0, 520.0, 210.0, 1_500.0, 450.0])
		.addColumn("debt", [300.0, 0.0, 120.0, 40.0, 0.0, 600.0, 75.0])
		.addColumn("overdue", [12, 0, 3, 0, 0, 21, 5])
		.addColumn("id", ["b1", "b2", "b3", "b4", "b5", "b6", "b7"]);
}

FeedItem[] notifications()
{
	return [
		FeedItem("Payment overdue: **Initech**", "21 days past the due date, 600 € open.", "09:12", "error", true, null, ["Initech", "overdue"]),
		FeedItem("Plan exceeded: **Globex · Widget**", "Fact 520 € against a plan of 400 €.", "08:40", "warning", true, null, ["Globex"]),
		FeedItem("New supplier added", "Umbrella was added by Bob.", "yesterday", "info", false, null, ["Umbrella"]),
		FeedItem("Sync finished", "MSSQL → PostgreSQL, 12,431 rows.", "yesterday", "success", false, null, null),
	];
}

void overview(St st)
{
	st.title("Overview");
	auto period = st.segmentedControl("Period", ["Week", "Month", "Quarter"], 1, key: "period", required: true);
	auto df = purchases();
	auto kpi = st.columns(3);
	kpi[0].metric("Fact", format("%,.0f €", df.sum("fact")), "+4.2%", chartData: [4.8, 5.0, 5.1, 4.9, 5.3, 5.51],
		caption: "was 5,288 € last " ~ period.to!string, border: true);
	kpi[1].metric("Debt", format("%,.0f €", df.sum("debt")), "-12%", deltaColor: "inverse", chartData: [1.6, 1.5, 1.4, 1.3, 1.1, 1.135],
		chartType: "area", border: true);
	kpi[2].metric("Overdue suppliers", 3, "+1", deltaColor: "inverse", chartData: [1.0, 2, 2, 3, 2, 3], chartType: "bar", border: true);
	st.details([["Suppliers", "4"], ["Brands", "7"], ["Managers", "2"], ["Updated", "09:12"]], inline: true);

	st.subheader("Debt by status");
	st.proportionBar([1_135.0, 450.0, 2_100.0], ["Overdue", "Due this week", "Not due"], ["error", "warning", "success"],
		format: "%,.0f €");

	st.subheader("Sections");
	auto cards = st.columns(2);
	with (cards[0].card("Suppliers", "Plan and fact by brand", icon: "🏭", link: "suppliers"))
		caption("4 suppliers · 7 brands");
	with (cards[1].card("Inbox", "Alerts and notifications", icon: "🔔", link: "inbox"))
		caption("2 unread");
}

void suppliers(St st)
{
	st.title("Suppliers");
	st.breadcrumbs();
	auto df = purchases();
	auto sel = st.dataframe(df, hideIndex: true, groupBy: ["manager", "supplier"], expanded: 1, onSelect: "rerun",
		rowKey: "id", key: "suppliers", maxHeight: 520,
		columnConfig: [
			"brand": C.text("Brand", pinned: true),
			"plan": C.number("Plan", format: "%,.0f", group: "Purchases, €"),
			"fact": C.number("Fact", format: "%,.0f", background: "heat", group: "Purchases, €"),
			"debt": C.number("Debt", format: "%,.0f", group: "Payments"),
			"overdue": C.number("Overdue, days", format: "%d", group: "Payments", help: "Days past the due date of the oldest unpaid invoice"),
			"id": C.hide(),
		],
		totals: ["brand": "Total", "plan": "sum", "fact": "sum", "debt": "sum", "overdue": "max"],
		cellStyle: (size_t r, string col, Json v) => col == "overdue" && v.get!long > 14 ? "bg:error bold"
			: col == "overdue" && v.get!long > 0 ? "bg:warning" : null);
	st.legend([LegendItem("Overdue more than 14 days", "error"), LegendItem("Overdue", "warning"),
		LegendItem("More purchases", "primary")], "Colours");
	if (sel.keys.length)
		st.info("Selected brand **" ~ df.cell(sel.rows[0], "brand").get!string ~ "** (" ~ sel.keys[0].get!string ~ ")");
	else if (sel.group.length)
		st.info("Selected group **" ~ sel.group.join(" › ") ~ "**");

	st.subheader("Export");
	// built only when clicked, not on every run
	st.downloadButton("Download CSV", () => purchases().toCsv(), "suppliers.csv", "text/csv", icon: "⬇️");
}

void inbox(St st)
{
	st.title("Inbox");
	auto all = notifications();
	auto show = st.segmentedControl("Show", ["Unread", "All"], 0, key: "inbox-show", required: true);
	auto items = show == "Unread" ? all.filter!(n => n.unread).array : all;
	if (!items.length)
	{
		st.emptyState("No unread notifications", "New alerts appear here.", "📭");
		return;
	}
	auto page = st.pagination(items.length, 3, key: "inbox-page");
	st.feed(items[(page - 1) * 3 .. $ < page * 3 ? $ : page * 3]);
}

void plan(St st)
{
	st.title("Order plan");
	auto rows = [
		GridRow("acme", "ACME", null, "3 / 5 delivered", 0.6, 0.7),
		GridRow("rocket", "Rocket", "acme"),
		GridRow("anvil", "Anvil", "acme"),
		GridRow("initech", "Initech", null, "1 / 3 delivered", 0.33, 0.5),
		GridRow("printer", "Printer", "initech"),
	];
	auto items = [
		GridItem("d1", "rocket", Date(2026, 11, 3), Date.init, "Delivery 1 · 400 €", 400, "dot", "success"),
		GridItem("d2", "rocket", Date(2026, 11, 17), Date.init, "Delivery 2 · 650 €", 650, "dot", "success"),
		GridItem("d3", "rocket", Date(2026, 11, 24), Date.init, "Delivery 3 · 900 €", 900, "dot", "primary", true),
		GridItem("d4", "anvil", Date(2026, 11, 10), Date.init, "Delivery · 200 €", 200, "square", "error"),
		GridItem("p1", "anvil", Date(2026, 11, 20), Date(2026, 11, 27), "Payment window", double.nan, null, "info"),
		GridItem("d5", "printer", Date(2026, 12, 2), Date.init, "Delivery · 1,500 €", 1_500, "diamond", "warning"),
	];
	// ?focus=d3 scrolls to and highlights that delivery (e.g. a link from a notification)
	auto ev = st.calendarGrid(rows, items, Date(2026, 11, 1), Date(2026, 12, 31), key: "plan", today: Date(2026, 11, 18),
		summaryLabel: "Delivered", expanded: 1, focus: st.queryParams.get("focus"));
	st.legend([LegendItem("Delivered", "success", "circle"), LegendItem("Planned", "primary", "circle"),
		LegendItem("Late", "error", "square"), LegendItem("Payment window", "info", "line")]);
	if (ev.kind == "item")
		st.session["open"] = ev.item;
	auto open = st.session.get!string("open", null);
	if (open.length)
		st.dialog("Delivery " ~ open, (St d) {
			d.details([["Item", open], ["Status", "planned"]]);
			if (d.button("Change date"))
				st.session["editing"] = true;
			// a dialog opened from a dialog opens on top of it
			if (st.session.get!bool("editing", false))
				st.dialog("Change date of " ~ open, (St e) {
					auto when = e.dateInput("New date", Date(2026, 11, 26), key: "new-date");
					if (e.button("Save", type: "primary"))
					{
						st.session["editing"] = false;
						st.session["open"] = "";
						st.toast("Moved " ~ open ~ " to " ~ when.toISOExtString);
						st.rerun();
					}
				}, onDismiss: { st.session["editing"] = false; });
			if (d.button("Close"))
			{
				st.session["open"] = "";
				st.session["editing"] = false;
				st.rerun();
			}
		}, width: "large", onDismiss: { st.session["open"] = ""; st.session["editing"] = false; }); // × and Esc close it for good
	if (ev.kind == "row")
		st.toast("Row " ~ ev.row);
	if (ev.kind == "cell")
		st.toast("Add a delivery for " ~ ev.row ~ " on " ~ ev.date.toISOExtString);
}

void about(St st)
{
	st.title("About this session");
	auto c = st.context;
	st.details([["Language", c.locale], ["Time zone", c.timezone], ["Client address", c.ip],
		["Browser", c.header("User-Agent")], ["Page", c.url]]);
	st.caption("st.context: request headers, cookies (e.g. a portal's single-sign-on cookie), language and time zone.");
}

void app(St st)
{
	st.setPageConfig(title: "Purchasing", icon: "🏭", layout: Layout.wide);
	auto unread = notifications().filter!(n => n.unread).array.length;
	auto page = st.navigation([
		Page(&overview, "Overview", "📊"),
		Page(&suppliers, "Suppliers", "🏭", section: "Purchasing"),
		Page(&inbox, "Inbox", "🔔", section: "Purchasing", badge: unread ? unread.to!string : null),
		Page(&plan, "Order plan", "🗓️", section: "Purchasing"),
		Page(&about, "About", "ℹ️", section: "Help"),
	], sections: "collapsible");
	page.run(st);
}

mixin StreamlitMain!app;
