/// A project: phases, tasks with dates, progress, owners and dependencies. Shared by everyone
/// who opens the app, kept in a JSON file.
module gantt.store;

import core.sync.mutex : Mutex;
import core.time : days;
import std.algorithm : canFind, filter, map, maxElement, minElement;
import std.array : array;
import std.conv : to;
import std.datetime : Clock, Date;
import vibe.data.json;
import streamlitd : cacheResource, refreshFragments;

enum topic = "gantt";
/// Tasks lie within this many years of today; names are at most `maxName` characters.
enum maxYears = 5, maxName = 100;
immutable people = ["Ann", "Bob", "Chen", "Dana"];

struct Phase
{
	string id;
	string name;
}

struct GTask
{
	string id;
	string phase;        /// Phase.id
	string name;
	string start;        /// "YYYY-MM-DD"
	string end;          /// last day, included
	double progress = 0; /// 0..1
	string assignee;
	string[] dependsOn;  /// ids of tasks that must end before this one starts
	bool milestone;      /// one day, drawn as a diamond

	Date startDate() const { return Date.fromISOExtString(start); }
	Date endDate() const { return Date.fromISOExtString(end); }
	long days_() const { return (endDate - startDate).total!"days" + 1; }
	bool done() const { return progress >= 1; }
	/// Should be done by now, but isn't.
	bool late(Date today) const { return !done && endDate < today; }
	/// Behind: less progress than the share of its time that has passed.
	double expected(Date today) const
	{
		if (today < startDate) return 0;
		if (today > endDate) return 1;
		return cast(double) ((today - startDate).total!"days" + 1) / days_;
	}
}

/// A scheduling problem: `task` starts before `dependency` ends.
struct Conflict
{
	GTask task;
	GTask dependency;
}

private __gshared Date g_today;

Date today()
{
	import std.process : environment;
	if (g_today != Date.init)
		return g_today;
	if (auto s = environment.get("GANTT_TODAY"))
		return Date.fromISOExtString(s);
	return cast(Date) Clock.currTime;
}

void useToday(Date d) { g_today = d; }

final class Store
{
	private Mutex lock;
	private string path;
	private bool push;
	private Phase[] phases_;
	private GTask[] tasks_;
	private int nextId = 1;

	this(string path, bool push = true)
	{
		import std.file : exists, readText;
		lock = new Mutex;
		this.path = path;
		this.push = push;
		if (path.length && path.exists)
		{
			auto j = parseJsonString(readText(path));
			phases_ = deserializeJson!(Phase[])(j["phases"]);
			tasks_ = deserializeJson!(GTask[])(j["tasks"]);
			nextId = j["nextId"].get!int;
		}
		else
			seed();
	}

	Phase[] phases() { synchronized (lock) return phases_.dup; }
	GTask[] tasks() { synchronized (lock) return tasks_.dup; }

	GTask task(string id)
	{
		synchronized (lock)
			foreach (t; tasks_)
				if (t.id == id)
					return t;
		return GTask.init;
	}

	/// What is wrong with a task, or null. Everyone sees the same chart, so a task that can't be
	/// drawn (a date in year 9999, an end before its start) must never be saved.
	string problemOf(GTask t)
	{
		import std.algorithm : canFind;
		import std.math : isFinite;
		import std.string : strip;
		import std.utf : count;
		if (!t.name.strip.length)
			return "Give the task a name.";
		if (t.name.count > maxName)
			return "The name is longer than " ~ maxName.to!string ~ " characters.";
		Date a, b;
		try
		{
			a = t.startDate;
			b = t.endDate;
		}
		catch (Exception)
			return "Choose the dates.";
		if (b < a)
			return "The task ends before it starts.";
		auto lo = today - (365 * maxYears).days, hi = today + (365 * maxYears).days;
		if (a < lo || b > hi)
			return "Tasks must lie within " ~ maxYears.to!string ~ " years of today.";
		if (!isFinite(t.progress) || t.progress < 0 || t.progress > 1)
			return "Progress must be between 0 and 100 %.";
		if (!people.canFind(t.assignee))
			return "Unknown assignee.";
		if (!phases.canFind!(p => p.id == t.phase))
			return "Unknown phase.";
		auto ids = tasks.map!(x => x.id).array;
		foreach (d; t.dependsOn)
			if (d == t.id || !ids.canFind(d))
				return "A dependency is not a task.";
		return null;
	}

	/// Add or replace a task (by id; a new one gets an id). Returns its id. Throws when
	/// `problemOf` finds a problem.
	string put(GTask t)
	{
		if (auto p = problemOf(t))
			throw new Exception(p);
		synchronized (lock)
		{
			bool found;
			foreach (ref x; tasks_)
				if (t.id.length && x.id == t.id)
				{
					x = t;
					found = true;
				}
			if (!found)
			{
				t.id = "t" ~ (nextId++).to!string;
				tasks_ ~= t;
			}
			save();
		}
		changed();
		return t.id;
	}

	/// Remove a task, and it from the dependencies of others.
	void remove(string id)
	{
		synchronized (lock)
		{
			tasks_ = tasks_.filter!(t => t.id != id).array;
			foreach (ref t; tasks_)
				t.dependsOn = t.dependsOn.filter!(d => d != id).array;
			save();
		}
		changed();
	}

	version (unittest) void change_for_tests(void delegate(ref GTask[]) fn)
	{
		synchronized (lock)
			fn(tasks_);
	}

	/// Tasks that start before a task they depend on has ended.
	Conflict[] conflicts()
	{
		Conflict[] r;
		auto ts = tasks;
		foreach (t; ts)
			foreach (d; t.dependsOn)
				foreach (x; ts)
					if (x.id == d && t.startDate <= x.endDate)
						r ~= Conflict(t, x);
		return r;
	}

	/// First and last day of the project.
	Date[2] span()
	{
		auto ts = tasks;
		if (!ts.length)
			return [today, today + 30.days];
		// clamped: whatever is stored, the chart stays drawable (calendarGrid takes up to ~10 years)
		auto lo = today - (365 * maxYears).days, hi = today + (365 * maxYears).days;
		auto a = ts.map!(t => t.startDate).minElement, b = ts.map!(t => t.endDate).maxElement;
		return [a < lo ? lo : a > hi ? hi : a, b > hi ? hi : b < lo ? lo : b];
	}

	private void changed()
	{
		if (push)
			refreshFragments(topic);
	}

	// caller holds the lock
	private void save()
	{
		import std.file : write, rename, mkdirRecurse, exists;
		import std.path : dirName;
		if (!path.length)
			return;
		if (path.dirName.length && !path.dirName.exists)
			mkdirRecurse(path.dirName);
		auto j = Json.emptyObject;
		j["phases"] = serializeToJson(phases_);
		j["tasks"] = serializeToJson(tasks_);
		j["nextId"] = nextId;
		write(path ~ ".tmp", j.toPrettyString);
		rename(path ~ ".tmp", path);
	}

	/// A website relaunch around today: some work done, some late, one dependency problem.
	private void seed()
	{
		auto t0 = today - 24.days;
		phases_ = [Phase("discovery", "Discovery"), Phase("design", "Design"), Phase("build", "Build"), Phase("launch", "Launch")];
		GTask mk(string phase, string name, int from, int len, double progress, string who, string[] deps = null,
			bool milestone = false)
		{
			auto s = t0 + from.days;
			return GTask("t" ~ (nextId++).to!string, phase, name, s.toISOExtString, (s + (len - 1).days).toISOExtString,
				progress, who, deps, milestone);
		}
		tasks_ = [
			mk("discovery", "Interviews", 0, 8, 1, "Ann"),                          // t1
			mk("discovery", "Analytics review", 3, 7, 1, "Chen"),                   // t2
			mk("discovery", "Requirements signed off", 10, 1, 1, "Ann", ["t1", "t2"], true), // t3
			mk("design", "Wireframes", 11, 9, 1, "Dana", ["t3"]),                   // t4
			mk("design", "Visual design", 17, 10, 0.6, "Dana", ["t4"]),             // t5: starts before t4 ends
			mk("design", "Design review", 29, 1, 0, "Ann", ["t5"], true),           // t6
			mk("build", "Content migration", 12, 12, 0.5, "Chen"),                  // t7: late (ended yesterday)
			mk("build", "Frontend", 27, 18, 0, "Bob", ["t5"]),                      // t8
			mk("build", "Backend API", 22, 20, 0.15, "Bob", ["t3"]),                // t9
			mk("launch", "Testing", 45, 8, 0, "Chen", ["t8", "t9"]),                // t10
			mk("launch", "Go live", 53, 1, 0, "Ann", ["t10"], true),                // t11
		];
	}
}

private __gshared Store g_store;

Store store()
{
	if (g_store !is null)
		return g_store;
	return cacheResource!openStore(dataPath());
}

private Store openStore(string path) { return new Store(path); }

string dataPath()
{
	import std.process : environment;
	return environment.get("GANTT_DATA", "data/gantt.json");
}

void useStore(Store s) { g_store = s; }
