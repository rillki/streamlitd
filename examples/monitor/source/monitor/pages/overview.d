/// Overview: KPI tiles with trends and a rolling chart, pushed by the producer on every sample;
/// below, a slow legacy source checked off the event loop, and only when its data changed.
module monitor.pages.overview;

import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.datetime : Clock;
import std.format : format;
import streamlitd;
import monitor.metrics;
import monitor.ui;

/// What the slow source returns.
struct Inventory
{
	long items;
	long lowStock;
	long version_;
}

/// A legacy system that answers in about two seconds and blocks the calling thread while it does
/// (`MONITOR_SLOW_MS` shortens it in tests).
Inventory slowInventory(long dataVersion)
{
	import std.process : environment;
	Thread.sleep(environment.get("MONITOR_SLOW_MS", "2000").to!int.msecs);
	return Inventory(12_000 + dataVersion * 37 % 900, 3 + dataVersion % 5, dataVersion);
}

void overview(St st)
{
	st.title("Operations");
	auto ctx = st.context;
	auto offset = ctx.timezoneOffset;
	st.caption("Times in your time zone: " ~ (ctx.timezone.length ? ctx.timezone : "UTC") ~ ".");

	// pushed: the producer calls refreshFragments("metrics") after every sample
	st.fragment((St f) {
		auto m = metrics;
		auto k = f.columns(3);
		static immutable labels = ["Average CPU", "Average latency", "Error rate"];
		foreach (i, name; metricNames)
		{
			auto avg = averages(m, name, 30);
			if (!avg.length)
				continue;
			auto fmt = name == "latency" ? "%.0f" : name == "errors" ? "%.2f" : "%.1f";
			k[i].metric(labels[i], format(fmt, avg[$ - 1]) ~ unit(name), format("%+" ~ fmt[1 .. $], avg[$ - 1] - avg[0]) ~ unit(name),
				deltaColor: "inverse", chartData: avg, chartType: name == "errors" ? "bar" : "line",
				caption: "last 30 samples", border: true);
		}
		f.subheader("Latency by service");
		f.lineChart(series(m, "latency", services.dup, 60), x: "time", y: ["latency"], color: "service", height: 260);
		auto last = m.samples("api", 1);
		if (last.length)
			f.caption("Sample " ~ m.ticks.to!string ~ " at " ~ localTime(last[0].at, offset));
	}, refreshOn: metricsTopic, key: "overview");

	st.subheader("Inventory");
	st.caption("From a slow legacy system: checked every 5 s, but only when its data changed, and off the event "
		~ "loop, so other viewers don't wait.");
	auto seen = new long;
	*seen = -1;
	st.fragment((St f) {
		auto v = metrics.inventoryVersion;
		*seen = v;
		auto inv = blocking(() => slowInventory(v)); // the other sessions on this thread go on meanwhile
		auto c = f.columns(2);
		c[0].metric("Items in stock", format("%,d", inv.items));
		c[1].metric("Low on stock", inv.lowStock, deltaColor: "off");
		f.caption("Checked at " ~ localTime(nowMs, offset) ~ " · data version " ~ v.to!string);
	}, runEvery: 5, refreshWhen: () => metrics.inventoryVersion != *seen, key: "inventory");
}
