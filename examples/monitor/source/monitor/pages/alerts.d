/// Alerts: what fired (newest first, unacknowledged ones highlighted), acknowledging them, and
/// the rules, edited in a table.
module monitor.pages.alerts;

import std.algorithm : canFind, filter, map, reverse;
import std.array : array;
import std.conv : to;
import std.format : format;
import std.string : strip;
import streamlitd;
import monitor.metrics;
import monitor.ui;

alias C = ColumnConfig;

/// Rules from the edited table; problems (empty when fine).
package(monitor) Rule[] rulesFrom(DataFrame df, out string[] problems)
{
	Rule[] r;
	foreach (i; 0 .. df.length)
	{
		auto line = "Rule " ~ (i + 1).to!string ~ ": ";
		auto svc = df.cell(i, "service").opt!string(null);
		auto metric = df.cell(i, "metric").opt!string(null);
		auto sev = df.cell(i, "severity").opt!string(null);
		auto th = df.cell(i, "threshold");
		if (!svc.length || !metric.length || !sev.length) { problems ~= line ~ "fill in every column."; continue; }
		if (th.type != Json.Type.float_ && th.type != Json.Type.int_) { problems ~= line ~ "the threshold is missing."; continue; }
		double v = th.type == Json.Type.int_ ? th.get!long : th.get!double;
		import std.math : isFinite;
		if (!isFinite(v) || v < 0) { problems ~= line ~ "the threshold must be 0 or more."; continue; }
		if (!services.canFind(svc) && svc != "*") { problems ~= line ~ "unknown service."; continue; }
		r ~= Rule(svc, metric, v, sev);
	}
	return r;
}

void alertsPage(St st)
{
	st.title("Alerts");
	auto offset = st.context.timezoneOffset;
	auto who = st.user.isLoggedIn ? st.user.username : "operator";
	auto tabs = st.tabs(["Fired", "Rules"]);

	// new alerts and acknowledgements arrive by themselves (topic "alerts")
	tabs[0].fragment((St f) {
		auto m = metrics;
		auto all = m.alerts;
		all.reverse();
		auto open = all.filter!(a => !a.acked).array.length;
		auto c = f.columns([2.0, 3]);
		if (c[0].button(open ? "Acknowledge all (" ~ open.to!string ~ ")" : "Nothing to acknowledge", disabled: !open,
			type: "primary"))
		{
			m.acknowledge(who);
			st.toast("Acknowledged " ~ open.to!string ~ " alerts", "✅");
			st.rerun("fragment"); // draw the list again, without them
		}
		auto show = c[1].segmentedControl("Show", ["Open", "All"], 0, key: "alert-filter", required: true,
			labelVisibility: "collapsed");
		auto list = show == "Open" ? all.filter!(a => !a.acked).array : all;
		if (!list.length)
		{
			f.emptyState("All quiet", show == "Open" ? "No open alerts." : "Nothing has fired yet.", "🌙");
			return;
		}
		auto page = list.length > 8 ? f.pagination(list.length, 8, key: "alert-page") : 1;
		auto from = (page - 1) * 8, to_ = from + 8 < list.length ? from + 8 : list.length;
		FeedItem[] items;
		foreach (a; list[from .. to_])
			items ~= FeedItem(format("**%s** %s %.1f%s > %g", a.service, a.metric, a.value, unit(a.metric), a.threshold),
				a.acked ? "Acknowledged by " ~ a.ackedBy : null, localTime(a.at, offset), a.severity, !a.acked, null,
				[a.service, a.metric]);
		f.feed(items);
	}, refreshOn: alertsTopic, key: "fired");

	with (tabs[1])
	{
		auto m = metrics;
		Json[][] rows;
		foreach (r; m.rules)
			rows ~= [Json(r.service), Json(r.metric), Json(r.threshold), Json(r.severity)];
		auto edited = dataEditor(DataFrame.fromRows(["service", "metric", "threshold", "severity"], rows), key: "rules",
			numRows: "dynamic", hideIndex: true, maxRows: maxRules, columnConfig: [
				"service": C.select("Service", ["*"] ~ services.dup, required: true, help: "* = every service"),
				"metric": C.select("Metric", metricNames.dup, required: true),
				"threshold": C.number("Above", min: 0, required: true),
				"severity": C.select("Severity", ["warning", "error"], required: true),
			]);
		string[] problems;
		auto next = rulesFrom(edited, problems);
		foreach (p; problems)
			error(p);
		if (button("Save rules", type: "primary", disabled: problems.length > 0))
		{
			m.setRules(next);
			st.resetWidgets("rules");
			st.toast("Saved " ~ next.length.to!string ~ " rules");
			st.rerun();
		}
	}
}
