/// Plan vs fact: a tree (manager › supplier › brand) with grouped headers, Δ coloured by sign,
/// heat on the fact, totals; a brand selected shows its months.
module planning.pages.actuals;

import std.algorithm : sum;
import std.conv : to;
import streamlitd;
import planning.store;
import planning.ui;

/// One row per brand: year to date (closed months) and the full year (fact + open plan).
DataFrame actualsFrame(Store s)
{
	Json[][] rows;
	string[string] managerOf;
	foreach (x; s.suppliers)
		managerOf[x.id] = x.manager;
	foreach (b; s.brands)
	{
		double plan = 0, fact = 0, forecast = 0;
		foreach (m; 0 .. 12)
		{
			if (isClosed(m + 1))
			{
				plan += b.plan[m];
				fact += b.fact[m];
				forecast += b.fact[m];
			}
			else
				forecast += b.plan[m];
		}
		rows ~= [Json(b.id), Json(managerOf.get(b.supplier, "—")), Json(s.supplierName(b.supplier)), Json(b.name),
			Json(plan), Json(fact), Json(fact - plan), Json(plan ? fact / plan : 0.0), Json(b.plan[].sum), Json(forecast)];
	}
	return DataFrame.fromRows(["id", "manager", "supplier", "brand", "plan", "fact", "delta", "done", "yearPlan",
		"forecast"], rows);
}

void actualsPage(St st)
{
	st.title("Plan vs fact");
	// other users' saves update this page while it is open
	st.fragment((St f) {
		auto s = store;
		auto df = actualsFrame(s);
		auto ytd = today.month > 1 ? "Year to date (Jan–" ~ monthNames[today.month - 2] ~ ")" : "Year to date";
		auto sel = f.dataframe(df, hideIndex: true, groupBy: ["manager", "supplier"], expanded: 1, onSelect: "rerun",
			rowKey: "id", key: "actuals", maxHeight: 460,
			columnConfig: [
				"id": C.hide(),
				"brand": C.text("Brand", pinned: true),
				"plan": C.number("Plan", format: "%,.0f", group: ytd),
				"fact": C.number("Fact", format: "%,.0f", background: "heat", group: ytd),
				"delta": C.number("Δ", format: "%+,.0f", color: "sign", group: ytd),
				"done": C.progress("Fact / plan", min: 0, max: 1.5, format: "percent", group: ytd),
				"yearPlan": C.number("Plan", format: "%,.0f", group: "Full year"),
				"forecast": C.number("Forecast", format: "%,.0f", group: "Full year",
					help: "Fact of the closed months plus the plan of the open ones"),
			],
			totals: ["brand": "Total", "plan": "sum", "fact": "sum", "delta": "sum", "yearPlan": "sum", "forecast": "sum"]);
		f.legend([LegendItem("Above plan", "success"), LegendItem("Below plan", "error")]);

		if (!sel.keys.length)
		{
			f.caption("Select a brand to see its months.");
			return;
		}
		auto b = s.brand(sel.keys[0].get!string);
		if (!b.id.length)
			return;
		f.subheader(escapeMarkdown(b.name ~ " · " ~ s.supplierName(b.supplier)));
		// long format: one row per month and series; open months have no fact yet
		string[] months, series;
		double[] values;
		foreach (m; 0 .. 12)
		{
			months ~= monthNames[m]; series ~= "plan"; values ~= b.plan[m];
			if (isClosed(m + 1)) { months ~= monthNames[m]; series ~= "fact"; values ~= b.fact[m]; }
		}
		f.barChart(new DataFrame().addColumn("month", months).addColumn("series", series).addColumn("amount", values),
			x: "month", y: ["amount"], color: "series", stack: false, height: 240);
	}, refreshOn: topic, key: "actuals");

	st.downloadButton("Download fact (CSV)", () => actualsFrame(store).drop("id").toCsv(',', true), "fact.csv", "text/csv", icon: "⬇️");
}
