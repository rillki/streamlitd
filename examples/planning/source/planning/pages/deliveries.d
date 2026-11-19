/// Deliveries on a calendar: suppliers with their brands as rows, deliveries as markers sized by
/// amount. A click on a delivery opens it (with a nested "move" dialog); a click on an empty day
/// of a brand plans a new one there.
module planning.pages.deliveries;

import core.time : days;
import std.algorithm : count, filter;
import std.array : array;
import std.conv : to;
import std.datetime : Date;
import streamlitd;
import planning.store;

/// Rows and items of the calendar.
package(planning) void gridData(Store s, Date t, out GridRow[] rows, out GridItem[] items)
{
	auto ds = s.deliveries;
	string[string] supplierOf;
	foreach (b; s.brands)
		supplierOf[b.id] = b.supplier;
	foreach (sup; s.suppliers)
	{
		auto mine = ds.filter!(d => supplierOf.get(d.brand, null) == sup.id).array;
		auto done = mine.count!(d => d.delivered);
		auto due = mine.count!(d => d.date <= t);
		rows ~= GridRow(sup.id, sup.name, null, done.to!string ~ " / " ~ mine.length.to!string ~ " delivered",
			mine.length ? cast(double) done / mine.length : double.nan, mine.length ? cast(double) due / mine.length : double.nan);
		foreach (b; s.brands)
			if (b.supplier == sup.id)
				rows ~= GridRow(b.id, b.name, sup.id);
	}
	foreach (d; ds)
	{
		if (d.brand !in supplierOf)
			continue;
		auto late = !d.delivered && d.date < t;
		items ~= GridItem(d.id, d.brand, d.date, Date.init, s.brand(d.brand).name ~ " · " ~ money(d.amount)
			~ (d.delivered ? " · delivered" : late ? " · late" : " · planned"), d.amount, late ? "square" : "dot",
			d.delivered ? "success" : late ? "error" : "info", !d.delivered && !late);
	}
}

void deliveriesPage(St st)
{
	st.title("Deliveries");
	st.fragment((St f) {
		auto s = store;
		auto t = today;
		auto unit = f.segmentedControl("Scale", ["week", "day"], 0, key: "scale", required: true);
		GridRow[] rows;
		GridItem[] items;
		gridData(s, t, rows, items);
		auto ev = f.calendarGrid(rows, items, t - 28.days, t + 56.days, unit: unit, key: "deliveries", today: t,
			summaryLabel: "Delivered", expanded: 1, focus: st.queryParams.get("focus"));
		f.legend([LegendItem("Delivered", "success", "circle"), LegendItem("Planned", "info", "circle"),
			LegendItem("Late", "error", "square")]);
		f.caption("Click a delivery to open it, or an empty day of a brand to plan one.");

		if (ev.kind == "item")
			st.session["delivery"] = ev.item;
		if (ev.kind == "cell" && s.brand(ev.row).id.length)
		{
			st.session["new-brand"] = ev.row;
			st.session["new-date"] = ev.date.toISOExtString;
		}
		openDelivery(st, s);
		planDelivery(st, s);
	}, refreshOn: topic, key: "deliveries");
}

private void openDelivery(St st, Store s)
{
	auto id = st.session.get!string("delivery", null);
	if (!id.length)
		return;
	Delivery d;
	foreach (x; s.deliveries)
		if (x.id == id)
			d = x;
	if (!d.id.length)
		return;
	auto b = s.brand(d.brand);
	void close() { st.session["delivery"] = ""; st.session["moving"] = false; }
	st.dialog("Delivery · " ~ escapeMarkdown(b.name), (St dlg) {
		dlg.details([["Supplier", escapeMarkdown(s.supplierName(b.supplier))], ["Brand", escapeMarkdown(b.name)], ["Date", d.date.toISOExtString],
			["Amount", money(d.amount)], ["Status", d.delivered ? "delivered" : d.date < today ? ":red[late]" : "planned"]]);
		auto c = dlg.columns(3);
		if (!d.delivered && c[0].button("Mark delivered", type: "primary", key: "mark"))
		{
			s.updateDelivery(d.id, (ref Delivery x) { x.delivered = true; });
			close();
			st.toast("Delivered: " ~ escapeMarkdown(b.name), "📦");
			st.rerun();
		}
		if (!d.delivered && c[1].button("Move date…", key: "move"))
			st.session["moving"] = true;
		if (c[2].button("Close", key: "close-delivery"))
		{
			close();
			st.rerun();
		}
		// a dialog opened from this dialog
		if (st.session.get!bool("moving", false))
			st.dialog("Move the " ~ escapeMarkdown(b.name) ~ " delivery", (St m) {
				auto when = m.dateInput("New date", d.date, today, today + 365.days, key: "move-date");
				if (m.button("Move", type: "primary", key: "move-save"))
				{
					s.updateDelivery(d.id, (ref Delivery x) { x.date = when; });
					close();
					st.toast("Moved to " ~ when.toISOExtString);
					st.rerun();
				}
			}, key: "move", onDismiss: { st.session["moving"] = false; });
	}, key: "delivery", onDismiss: &close);
}

private void planDelivery(St st, Store s)
{
	auto brandId = st.session.get!string("new-brand", null);
	if (!brandId.length)
		return;
	auto b = s.brand(brandId);
	auto date = Date.fromISOExtString(st.session.get!string("new-date", today.toISOExtString));
	void close() { st.session["new-brand"] = ""; }
	st.dialog("Plan a delivery · " ~ escapeMarkdown(b.name), (St d) {
		auto when = d.dateInput("Date", date, key: "new-delivery-date");
		auto amount = d.numberInput("Amount", b.plan[when.month - 1] / 3, minValue: 1, step: 50, key: "new-delivery-amount", format: "%.0f");
		if (d.button("Plan it", type: "primary", key: "new-delivery-save"))
		{
			s.addDelivery(b.id, when, amount);
			close();
			st.toast("Planned: " ~ escapeMarkdown(b.name) ~ " on " ~ when.toISOExtString, "🗓️");
			st.rerun();
		}
	}, key: "new-delivery", onDismiss: &close);
}
