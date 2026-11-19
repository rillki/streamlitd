/// Tasks and lists, kept per user in one JSON file. A change refreshes the user's other open tabs.
module todo.store;

import core.sync.mutex : Mutex;
import std.algorithm : canFind, countUntil, filter, remove;
import std.array : array;
import std.conv : to;
import std.datetime : Clock, Date;
import vibe.data.json;
import streamlitd : cacheResource, refreshFragments;

immutable priorities = ["low", "normal", "high"];

/// Limits per person: sign-up is open, so one account must not be able to fill the disk.
enum maxTasks = 2000, maxLists = 50, maxTitle = 200, maxNotes = 5000, maxListName = 40;

/// A tag as stored: lower case letters, digits, `-` and `_` only (at most 30), or empty.
string cleanTag(string tag)
{
	import std.uni : isAlphaNum, toLower;
	import std.utf : byDchar;
	import std.conv : to;
	dchar[] r;
	foreach (dchar c; tag.byDchar)
		if ((isAlphaNum(c) || c == '-' || c == '_') && r.length < 30)
			r ~= toLower(c);
	return r.to!string;
}

/// Thrown when a person reaches a limit (the message is for them).
class LimitError : Exception
{
	this(string msg) { super(msg); }
}

struct TaskList
{
	string id;
	string name;
	string icon;
}

struct Task
{
	int id;
	string list;        /// TaskList.id
	string title;
	string notes;       /// Markdown
	string due;         /// "YYYY-MM-DD" or empty
	string priority = "normal";
	string[] tags;
	bool done;
	long created;

	Date dueDate() const { return due.length ? Date.fromISOExtString(due) : Date.init; }
	bool overdue(Date today) const { return !done && due.length && dueDate < today; }
}

/// One person's lists and tasks.
struct Board
{
	TaskList[] lists;
	Task[] tasks;
	int nextId = 1;
}

private __gshared Date g_today;

/// Today (fixed in tests with `useToday`, or by `TODO_TODAY=YYYY-MM-DD`).
Date today()
{
	import std.process : environment;
	if (g_today != Date.init)
		return g_today;
	if (auto s = environment.get("TODO_TODAY"))
		return Date.fromISOExtString(s);
	return cast(Date) Clock.currTime;
}

void useToday(Date d) { g_today = d; }

/// The topic of a user's pages: other tabs of the same person update.
string topicOf(string user) { return "todo:" ~ user; }

final class Store
{
	private Mutex lock;
	private string path;
	private bool push;
	private Board[string] boards;

	this(string path, bool push = true)
	{
		import std.file : exists, readText;
		lock = new Mutex;
		this.path = path;
		this.push = push;
		if (path.length && path.exists)
			boards = deserializeJson!(Board[string])(parseJsonString(readText(path)));
	}

	/// A copy of the user's board; a new user starts with example lists and tasks.
	Board board(string user)
	{
		synchronized (lock)
		{
			if (user !in boards)
			{
				boards[user] = starter();
				save();
			}
			auto b = boards[user];
			return Board(b.lists.dup, b.tasks.dup, b.nextId);
		}
	}

	/// Change the user's board; returns what `change` returns.
	T change(T = void)(string user, T delegate(ref Board) fn)
	{
		static if (!is(T == void))
			T r;
		synchronized (lock)
		{
			if (user !in boards)
				boards[user] = starter();
			static if (is(T == void))
				fn(boards[user]);
			else
				r = fn(boards[user]);
			save();
		}
		if (push)
			refreshFragments(topicOf(user));
		static if (!is(T == void))
			return r;
	}

	/// Add a task; returns it.
	Task add(string user, Task t)
	{
		return change!Task(user, (ref Board b) {
			if (b.tasks.length >= maxTasks)
				throw new LimitError("You have " ~ maxTasks.to!string ~ " tasks, the most there can be. Delete some first.");
			t.id = b.nextId++;
			t.created = Clock.currTime.toUnixTime;
			b.tasks ~= t;
			return t;
		});
	}

	/// Change some tasks.
	void update(string user, int[] ids, void delegate(ref Task) fn)
	{
		change(user, (ref Board b) {
			foreach (ref t; b.tasks)
				if (ids.canFind(t.id))
					fn(t);
		});
	}

	void removeTasks(string user, int[] ids)
	{
		change(user, (ref Board b) { b.tasks = b.tasks.filter!(t => !ids.canFind(t.id)).array; });
	}

	/// Add a list; returns its id.
	string addList(string user, string name, string icon)
	{
		return change!string(user, (ref Board b) {
			if (b.lists.length >= maxLists)
				throw new LimitError("You have " ~ maxLists.to!string ~ " lists, the most there can be.");
			auto id = "l" ~ (b.nextId++).to!string;
			b.lists ~= TaskList(id, name, icon);
			return id;
		});
	}

	/// Remove a list with its tasks (not the first one, the inbox).
	void removeList(string user, string id)
	{
		change(user, (ref Board b) {
			if (b.lists.length && b.lists[0].id == id)
				return;
			b.lists = b.lists.filter!(l => l.id != id).array;
			b.tasks = b.tasks.filter!(t => t.list != id).array;
		});
	}

	private static Board starter()
	{
		import core.time : days;
		auto t = today;
		Board b;
		b.lists = [TaskList("inbox", "Inbox", "📥"), TaskList("work", "Work", "💼"), TaskList("home", "Home", "🏠")];
		Task mk(string list, string title, int dueIn, string prio, string[] tags, bool done = false)
		{
			auto x = Task(b.nextId++, list, title, null, dueIn == int.min ? null : (t + dueIn.days).toISOExtString, prio, tags, done);
			return x;
		}
		b.tasks = [
			mk("inbox", "Try the quick add: “Call Anna #phone !high”", 0, "normal", ["tips"]),
			mk("inbox", "Select several tasks to complete or delete them at once", int.min, "low", ["tips"]),
			mk("work", "Send the quarterly report", -1, "high", ["reports"]),
			mk("work", "Review Bob's pull request", 0, "normal", ["code"]),
			mk("work", "Plan the team offsite", 7, "low", ["team"]),
			mk("work", "Update the supplier list", 2, "normal", ["reports"]),
			mk("home", "Buy groceries", 0, "normal", ["shopping"]),
			mk("home", "Book a dentist appointment", 3, "high", null),
			mk("home", "Fix the bike", int.min, "low", null, true),
		];
		return b;
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
		write(path ~ ".tmp", serializeToJson(boards).toPrettyString);
		rename(path ~ ".tmp", path);
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
	return environment.get("TODO_DATA", "data/todo.json");
}

void useStore(Store s) { g_store = s; }

/// Quick add: "Call Anna #phone !high ^tomorrow" → title, tags, priority, due date.
Task parseQuick(string text)
{
	import std.string : split, strip, join, toLower, startsWith;
	import core.time : days;
	Task t;
	string[] words;
	foreach (w; text.strip.split)
	{
		if (w.length > 1 && w[0] == '#')
		{
			auto tag = cleanTag(w[1 .. $]);
			if (tag.length && !t.tags.canFind(tag))
				t.tags ~= tag;
		}
		else if (w.length > 1 && w[0] == '!' && priorities.canFind(w[1 .. $].toLower))
			t.priority = w[1 .. $].toLower;
		else if (w.length > 1 && w[0] == '^')
		{
			auto d = w[1 .. $].toLower;
			if (d == "today") t.due = today.toISOExtString;
			else if (d == "tomorrow") t.due = (today + 1.days).toISOExtString;
			else
				try t.due = Date.fromISOExtString(d).toISOExtString;
				catch (Exception) words ~= w;
		}
		else
			words ~= w;
	}
	t.title = words.join(" ");
	return t;
}
