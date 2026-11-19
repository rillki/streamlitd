/// Shared parts: health of a service, local time labels, the chart data.
module monitor.ui;

import std.algorithm : map, sum;
import std.array : array;
import std.conv : to;
import std.datetime : SysTime, UTC, unixTimeToStdTime;
import std.format : format;
import streamlitd;
import monitor.metrics;

/// "ok", "warning" or "critical" from the latest sample.
string health(Sample s)
{
	if (s.errors > 2 || s.latency > 150 || s.cpu > 95) return "critical";
	if (s.errors > 1 || s.latency > 100 || s.cpu > 80) return "warning";
	return "ok";
}

/// "HH:MM:SS" in the viewer's time zone (from `st.context`; UTC when the browser didn't say).
string localTime(long ms, int offsetMinutes)
{
	auto t = SysTime(unixTimeToStdTime(ms / 1000 + offsetMinutes * 60L), UTC());
	return format("%02d:%02d:%02d", t.hour, t.minute, t.second);
}

/// A sample's time as a UTC timestamp (charts show it in the viewer's time zone).
SysTime timeOf(long ms) { return SysTime(unixTimeToStdTime(0) + ms * 10_000, UTC()); }

/// One metric of several services over time, as a long frame (time, service, value) for a chart.
DataFrame series(Metrics m, string metric, string[] svcs, size_t n)
{
	SysTime[] times;
	string[] names;
	double[] values;
	foreach (svc; svcs)
		foreach (s; m.samples(svc, n))
		{
			times ~= timeOf(s.at);
			names ~= svc;
			values ~= valueOf(s, metric);
		}
	return new DataFrame().addColumn("time", times).addColumn("service", names).addColumn(metric, values);
}

/// The average of one metric over all services at each of the last `n` samples.
double[] averages(Metrics m, string metric, size_t n)
{
	double[] r;
	auto per = services.map!(s => m.samples(s, n)).array;
	auto len = per.map!(p => p.length).array;
	if (!len.length || len[0] == 0)
		return r;
	foreach (i; 0 .. len[0])
	{
		double t = 0;
		foreach (p; per)
			t += i < p.length ? valueOf(p[i], metric) : 0;
		r ~= t / per.length;
	}
	return r;
}

string unit(string metric) { return metric == "cpu" ? "%" : metric == "latency" ? " ms" : "%"; }
