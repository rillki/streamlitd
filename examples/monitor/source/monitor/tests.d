/// Unit tests of the monitor (`dub test`): the producer's logic without its thread, the pages.
module monitor.tests;

version (unittest):

import std.algorithm : all, canFind, count, filter, min;
import std.array : array;
import std.conv : to;
import std.process : environment;
import streamlitd;
import streamlitd.testing;
import monitor.metrics;
import monitor.ui;
import monitor.pages.overview;
import monitor.pages.services;
import monitor.pages.alerts;

private Metrics fresh(int ticks)
{
	environment["MONITOR_SLOW_MS"] = "1";
	auto m = new Metrics(false);
	foreach (i; 0 .. ticks)
		m.tick();
	useMetrics(m);
	return m;
}

unittest // the ring keeps the last samples; alerts fire once per crossing; acknowledging
{
	auto m = fresh(39);
	assert(m.samples("db").length == 39 && m.samples("db", 5).length == 5);
	assert(!m.alerts.canFind!(a => a.service == "db" && a.metric == "latency"));
	m.tick(); // tick 40: the db's slow spell starts
	auto db = m.alerts.filter!(a => a.service == "db" && a.metric == "latency").array;
	assert(db.length == 1 && db[0].severity == "error" && db[0].value > 120);
	foreach (i; 0 .. 5)
		m.tick();
	assert(m.alerts.count!(a => a.service == "db" && a.metric == "latency") == 1); // still above: no new alert
	foreach (i; 0 .. 100)
		m.tick();
	assert(m.samples("api").length == keep);
	assert(m.alerts.count!(a => a.service == "db" && a.metric == "latency") == 2); // the next spell
	assert(m.unacked > 0);
	m.acknowledge("ann");
	assert(m.unacked == 0 && m.alerts.all!(a => a.ackedBy == "ann"));
	assert(m.inventoryVersion == 145 / 15);
}

unittest // health and the rules table
{
	assert(health(Sample(0, 50, 50, 0.5)) == "ok");
	assert(health(Sample(0, 85, 50, 0.5)) == "warning");
	assert(health(Sample(0, 50, 200, 0.5)) == "critical");
	string[] problems;
	auto df = DataFrame.fromRows(["service", "metric", "threshold", "severity"], [
		[Json("*"), Json("cpu"), Json(90), Json("warning")],
		[Json("db"), Json(null), Json(1.5), Json("error")],
		[Json("web"), Json("latency"), Json(null), Json("error")],
	]);
	auto rules = rulesFrom(df, problems);
	assert(rules.length == 1 && rules[0].threshold == 90 && problems.length == 2);
}

unittest // the overview: KPI tiles, the chart, the slow source (here without a task: blocking just calls it)
{
	fresh(40);
	auto at = new AppTest(&overview).run();
	assert(!at.exceptions.length, at.exceptions.to!string);
	assert(at.elements("metric").length == 5); // 3 KPIs + 2 inventory tiles
	assert(at.elements("vega_lite").length == 1);
	assert(at.markdowns.canFind!(m => m.canFind("data version 2")));
}

unittest // services: a selected one shows its charts
{
	fresh(40);
	auto at = new AppTest(&servicesPage).run();
	assert(!at.exceptions.length, at.exceptions.to!string);
	assert(at.elements("dataframe")[0]["data"].length == 5);
	at.selectRows("svc", 2).run();
	assert(at.headings.canFind("db") && at.elements("vega_lite").length == 3);
}

unittest // alerts: acknowledge all; edit the rules
{
	auto m = fresh(45);
	auto at = new AppTest(&alertsPage).run();
	assert(!at.exceptions.length, at.exceptions.to!string);
	auto open = m.unacked;
	assert(open > 0 && at.elements("feed").length == 1);
	at.click("Acknowledge all (" ~ open.to!string ~ ")").run();
	assert(m.unacked == 0);
	assert(at.elements("empty_state").length == 1);
	auto id = at.widgetId("data_editor", null);
	at.setValueById(id, parseJsonString(`{"edited": {"0": {"threshold": 99}}}`)).run();
	at.click("Save rules").run();
	assert(m.rules[0].threshold == 99);
}

unittest // a flapping rule can't grow the alert list forever; open alerts are kept before old acknowledged ones
{
	import std.exception : assertThrown;
	auto m = fresh(0);
	m.setRules([Rule("*", "cpu", 45, "warning")]);
	foreach (i; 0 .. 3000)
		m.tick();
	auto firstOpen = m.alerts[0].id;
	m.acknowledge("ann");
	foreach (i; 0 .. 20000)
		m.tick();
	assert(m.alerts.length <= keepAlerts);
	assert(!m.alerts.canFind!(a => a.id == firstOpen)); // old acknowledged ones went first
	assert(m.alerts.count!(a => !a.acked) == m.alerts.length); // the newer, open ones stayed
	assertThrown(m.setRules(new Rule[maxRules + 1]));
	string[] problems;
	rulesFrom(DataFrame.fromRows(["service", "metric", "threshold", "severity"],
		[[Json("db"), Json("cpu"), Json(-5), Json("error")], [Json("nope"), Json("cpu"), Json(5), Json("error")]]), problems);
	assert(problems.length == 2, problems.to!string);
}
