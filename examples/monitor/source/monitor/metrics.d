/// The data behind the monitor: a producer thread samples every service once a tick (simulated
/// here; a real app would poll its systems), keeps the last samples in a ring, checks the alert
/// rules, and tells the open pages (`refreshFragments`). Everything is shared by all viewers.
module monitor.metrics;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm : canFind, filter, map, max, min, sum;
import std.array : array;
import std.conv : to;
import std.datetime : Clock;
import std.math : sin;
import vibe.data.json;
import streamlitd : cacheResource, refreshFragments;

/// Topics: "metrics" on every tick, "alerts" only when an alert fires or is acknowledged.
enum metricsTopic = "metrics";
enum alertsTopic = "alerts";

immutable services = ["api", "web", "db", "queue", "search"];
immutable metricNames = ["cpu", "latency", "errors"];
enum keep = 120; /// samples kept per service
enum keepAlerts = 500; /// alerts kept: a rule that flaps would otherwise grow the list forever
enum maxRules = 20;

struct Sample
{
	long at;          /// Unix time, ms
	double cpu;       /// %
	double latency;   /// ms
	double errors;    /// % of requests
}

struct Rule
{
	string service;   /// a service, or "*" for all
	string metric;    /// "cpu", "latency", "errors"
	double threshold; /// fires when the value goes above it
	string severity;  /// "warning" or "error"
}

struct Alert
{
	int id;
	long at;          /// ms
	string service;
	string metric;
	double value;
	double threshold;
	string severity;
	bool acked;
	string ackedBy;
}

/// Milliseconds since 1970 (UTC).
long nowMs()
{
	import std.datetime : unixTimeToStdTime;
	return (Clock.currStdTime - unixTimeToStdTime(0)) / 10_000;
}

double valueOf(Sample s, string metric)
{
	switch (metric)
	{
		case "cpu": return s.cpu;
		case "latency": return s.latency;
		default: return s.errors;
	}
}

final class Metrics
{
	private Mutex lock;
	private Sample[][string] ring;
	private Rule[] rules_;
	private Alert[] alerts_;
	private bool[string] firing;  /// "service/metric/index" of rules above their threshold now
	private long tick_;
	private int nextAlert = 1;
	private long inventoryVersion_;
	private bool push;

	this(bool push = true)
	{
		lock = new Mutex;
		this.push = push;
		rules_ = [
			Rule("*", "cpu", 85, "warning"),
			Rule("db", "latency", 120, "error"),
			Rule("*", "errors", 2, "error"),
		];
	}

	/// Take one sample of every service (the producer calls it once a tick; tests call it directly).
	/// `at`: the sample time in ms (default now).
	void tick(long at = 0)
	{
		bool alertsChanged;
		synchronized (lock)
		{
			tick_++;
			auto now = at ? at : nowMs;
			foreach (i, svc; services)
			{
				auto t = tick_ + i * 17;
				// smooth load with some noise; the db has a slow spell every 60 ticks, the api an error burst
				double wave = sin(t / 9.0) * 12 + sin(t / 2.3) * 4;
				auto s = Sample(now, 35 + i * 8 + wave, 40 + i * 6 + wave * 1.5, 0.3 + (sin(t / 5.0) + 1) * 0.2);
				if (svc == "db" && tick_ % 60 >= 40)
				{
					s.latency += 110;
					s.cpu += 30;
				}
				if (svc == "api" && tick_ % 90 >= 80)
					s.errors += 3;
				s.cpu = min(100, max(0, s.cpu));
				auto r = ring.get(svc, null) ~ s;
				ring[svc] = r.length > keep ? r[$ - keep .. $] : r;
				// alerts fire when a value crosses a rule's threshold (not again while it stays above)
				foreach (k, rule; rules_)
				{
					if (rule.service != "*" && rule.service != svc)
						continue;
					auto v = valueOf(s, rule.metric);
					auto id = svc ~ "/" ~ rule.metric ~ "/" ~ k.to!string;
					if (v > rule.threshold && id !in firing)
					{
						firing[id] = true;
						alerts_ ~= Alert(nextAlert++, now, svc, rule.metric, v, rule.threshold, rule.severity);
						alertsChanged = true;
					}
					else if (v <= rule.threshold)
						firing.remove(id);
				}
			}
			if (alerts_.length > keepAlerts)
				trimAlerts();
			if (tick_ % 15 == 0)
				inventoryVersion_++;
		}
		if (push)
		{
			refreshFragments(metricsTopic);
			if (alertsChanged)
				refreshFragments(alertsTopic);
		}
	}

	// caller holds the lock: drop the oldest acknowledged alerts first, then the oldest open ones
	private void trimAlerts()
	{
		auto extra = alerts_.length - keepAlerts;
		Alert[] r;
		foreach (a; alerts_)
			if (extra && a.acked)
				extra--;
			else
				r ~= a;
		alerts_ = r[extra .. $];
	}

	/// The last `n` samples of a service, oldest first.
	Sample[] samples(string service, size_t n = keep)
	{
		synchronized (lock)
		{
			auto r = ring.get(service, null);
			return r[r.length > n ? $ - n : 0 .. $].dup;
		}
	}

	Rule[] rules() { synchronized (lock) return rules_.dup; }
	Alert[] alerts() { synchronized (lock) return alerts_.dup; }
	long ticks() { synchronized (lock) return tick_; }
	size_t unacked() { synchronized (lock) return alerts_.filter!(a => !a.acked).array.length; }
	/// Changes now and then (every 15 ticks): what the slow source depends on.
	long inventoryVersion() { synchronized (lock) return inventoryVersion_; }

	void setRules(Rule[] rs)
	{
		if (rs.length > maxRules)
			throw new Exception("at most " ~ maxRules.to!string ~ " rules");
		synchronized (lock)
		{
			rules_ = rs.dup;
			firing = null;
		}
	}

	/// Acknowledge alerts (all unacknowledged ones when `ids` is empty).
	void acknowledge(string who, int[] ids = null)
	{
		synchronized (lock)
			foreach (ref a; alerts_)
				if (!a.acked && (!ids.length || ids.canFind(a.id)))
				{
					a.acked = true;
					a.ackedBy = who;
				}
		if (push)
			refreshFragments(alertsTopic);
	}
}

/// The shared metrics, with the producer thread started on first use (once per process).
Metrics metrics()
{
	if (g_metrics !is null)
		return g_metrics;
	return cacheResource!startProducer(tickMs());
}

private __gshared Metrics g_metrics;

/// Tests: use these metrics (no producer thread).
void useMetrics(Metrics m) { g_metrics = m; }

private Metrics startProducer(int ms)
{
	auto m = new Metrics;
	foreach (i; 0 .. 30)
		m.tick(nowMs - (30 - i) * ms); // some history to start with, one tick apart
	auto t = new Thread({
		while (true)
		{
			Thread.sleep(ms.msecs);
			m.tick();
		}
	});
	t.isDaemon = true;
	t.start();
	return m;
}

/// Milliseconds between samples (`MONITOR_TICK_MS`, default 1000).
int tickMs()
{
	import std.process : environment;
	return environment.get("MONITOR_TICK_MS", "1000").to!int;
}
