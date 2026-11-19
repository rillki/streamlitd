/// Services: their health now, live; a selected one shows its charts.
module monitor.pages.services;

import std.conv : to;
import std.format : format;
import streamlitd;
import monitor.metrics;
import monitor.ui;

alias C = ColumnConfig;

void servicesPage(St st)
{
	st.title("Services");
	st.fragment((St f) {
		auto m = metrics;
		Json[][] rows;
		foreach (svc; services)
		{
			auto s = m.samples(svc, 1);
			if (!s.length)
				continue;
			rows ~= [Json(svc), Json(health(s[0])), Json(s[0].cpu), Json(s[0].latency), Json(s[0].errors)];
		}
		auto df = DataFrame.fromRows(["service", "health", "cpu", "latency", "errors"], rows);
		auto sel = f.dataframe(df, hideIndex: true, onSelect: "rerun", rowKey: "service", key: "svc",
			columnConfig: [
				"service": C.text("Service", pinned: true),
				"health": C.text("Health", width: "small"),
				"cpu": C.progress("CPU", min: 0, max: 100, format: "%.0f%%"),
				"latency": C.number("Latency", format: "%.0f ms"),
				"errors": C.number("Errors", format: "%.2f%%"),
			],
			cellStyle: (size_t r, string col, Json v) {
				if (col != "health") return null;
				auto h = v.get!string;
				return h == "critical" ? "bg:error bold" : h == "warning" ? "bg:warning" : "bg:success";
			});
		if (!sel.keys.length)
		{
			f.caption("Select a service to see its charts.");
			return;
		}
		auto svc = sel.keys[0].get!string;
		f.subheader(svc);
		auto c = f.columns(3);
		foreach (i, name; metricNames)
			c[i].areaChart(series(m, name, [svc], 120), x: "time", y: [name], height: 180);
	}, refreshOn: metricsTopic, key: "services");
}
