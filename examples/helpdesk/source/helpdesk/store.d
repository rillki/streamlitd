/// The helpdesk's data: tickets, customers and an activity log, shared by every session.
///
/// One `Store` per process, kept in a JSON file (written atomically). Every change goes through
/// `update`/`add`/`saveCustomers`, which save the file, log the activity, and call
/// `refreshFragments("helpdesk")` so that the other open tabs show the change at once.
module helpdesk.store;

import core.sync.mutex : Mutex;
import std.algorithm : canFind, filter, map, sort;
import std.array : array;
import std.datetime : Clock;
import vibe.data.json;
import std.conv : to;
import streamlitd : refreshFragments, escapeMarkdown;

/// Pushed to every open tab when the data changes.
enum topic = "helpdesk";

/// Longest ticket title and comment (characters).
enum maxTitle = 200, maxComment = 2000;

static immutable statuses = ["open", "pending", "solved", "closed"];
static immutable priorities = ["low", "normal", "high", "urgent"];
static immutable plans = ["free", "team", "enterprise"];

struct Comment
{
	string author;
	string text;
	long at;
}

struct Ticket
{
	int id;
	string title;
	string customer;   /// Customer.id
	string status;     /// one of `statuses`
	string priority;   /// one of `priorities`
	string assignee;   /// username, or empty
	long created;      /// Unix time
	long updated;
	long due;          /// answer by (SLA)
	Comment[] comments;

	bool isOpen() const { return status == "open" || status == "pending"; }
	bool overdue(long now) const { return isOpen && due < now; }
	/// Share of the SLA time used, 0..1 (1 = due now).
	double slaUsed(long now) const
	{
		if (!isOpen || due <= created) return isOpen ? 1 : 0;
		auto f = cast(double)(now - created) / (due - created);
		return f < 0 ? 0 : f > 1 ? 1 : f;
	}
}

struct Customer
{
	string id;
	string name;
	string plan;   /// one of `plans`
	int seats;
	string email;
}

struct Activity
{
	long at;
	string who;
	string what;   /// Markdown
	string type;   /// feed colour: info, success, warning, error
}

long now() { return Clock.currTime.toUnixTime; }

final class Store
{
	private Mutex lock;
	private string path;
	private Ticket[] tickets_;
	private Customer[] customers_;
	private Activity[] activity_;
	private int nextId = 1;
	private bool push = true; // tests switch the refresh off

	/// Open the store at `path` (created with demo data when missing); null path: in memory.
	this(string path, bool push = true)
	{
		lock = new Mutex;
		this.path = path;
		this.push = push;
		import std.file : exists, readText;
		if (path.length && path.exists)
		{
			auto j = parseJsonString(readText(path));
			tickets_ = deserializeJson!(Ticket[])(j["tickets"]);
			customers_ = deserializeJson!(Customer[])(j["customers"]);
			activity_ = deserializeJson!(Activity[])(j["activity"]);
			foreach (t; tickets_)
				if (t.id >= nextId)
					nextId = t.id + 1;
		}
		else
		{
			seed();
			save();
		}
	}

	// ------------------------------------------------ reading (copies, so callers can't change the store)

	Ticket[] tickets() { synchronized (lock) return tickets_.dup; }
	Customer[] customers() { synchronized (lock) return customers_.dup; }

	/// The newest `n` activities first.
	Activity[] activity(size_t n = 20)
	{
		synchronized (lock)
		{
			auto a = activity_.dup;
			a.sort!((x, y) => x.at > y.at);
			return a.length > n ? a[0 .. n] : a;
		}
	}

	/// A ticket by id (`Ticket.init` with id 0 when there is none).
	Ticket ticket(int id)
	{
		synchronized (lock)
			foreach (t; tickets_)
				if (t.id == id)
					return t;
		return Ticket.init;
	}

	string customerName(string id)
	{
		synchronized (lock)
			foreach (c; customers_)
				if (c.id == id)
					return c.name;
		return id;
	}

	// ------------------------------------------------ changes

	/// Change a ticket; `what` goes to the activity log. Returns false when there is no such ticket.
	bool update(int id, string who, string what, void delegate(ref Ticket) change, string type = "info")
	{
		synchronized (lock)
		{
			bool found;
			foreach (ref t; tickets_)
				if (t.id == id)
				{
					change(t);
					t.updated = now;
					found = true;
				}
			if (!found)
				return false;
			activity_ ~= Activity(now, who, what, type);
			saveLocked();
		}
		changed();
		return true;
	}

	/// Add a ticket (id, times and status are filled in); returns it.
	/// What is wrong with a new ticket's fields, or null.
	string problemOf(string title, string customer, string priority)
	{
		import std.algorithm : canFind;
		import std.string : strip;
		import std.utf : count;
		if (!title.strip.length)
			return "the title is required";
		if (title.count > maxTitle)
			return "the title is longer than " ~ maxTitle.to!string ~ " characters";
		if (!priorities.canFind(priority))
			return "priority must be one of " ~ priorities.to!string;
		synchronized (lock)
			if (!customers_.canFind!(c => c.id == customer))
				return "unknown customer \"" ~ customer ~ "\"";
		return null;
	}

	/// Open a ticket; throws when `problemOf` finds a problem.
	Ticket add(string who, string title, string customer, string priority, long dueInHours = 24)
	{
		import std.string : strip;
		if (auto p = problemOf(title, customer, priority))
			throw new Exception(p);
		title = title.strip;
		Ticket t;
		synchronized (lock)
		{
			t.id = nextId++;
			t.title = title;
			t.customer = customer;
			t.priority = priority;
			t.status = "open";
			t.created = t.updated = now;
			t.due = now + dueInHours * 3600;
			tickets_ ~= t;
			activity_ ~= Activity(now, who, "opened **#" ~ idText(t.id) ~ "** " ~ escapeMarkdown(title), "info");
			saveLocked();
		}
		changed();
		return t;
	}

	/// Replace the customer list (validated by the caller).
	void saveCustomers(string who, Customer[] cs)
	{
		synchronized (lock)
		{
			customers_ = cs.dup;
			activity_ ~= Activity(now, who, "updated the customer list", "info");
			saveLocked();
		}
		changed();
	}

	private void changed()
	{
		if (push)
			refreshFragments(topic); // the other open tabs show the change now
	}

	private void save() { synchronized (lock) saveLocked(); }

	private void saveLocked()
	{
		if (!path.length)
			return;
		import std.file : write, rename, mkdirRecurse, exists;
		import std.path : dirName;
		if (path.dirName.length && !path.dirName.exists)
			mkdirRecurse(path.dirName);
		auto j = Json.emptyObject;
		j["tickets"] = serializeToJson(tickets_);
		j["customers"] = serializeToJson(customers_);
		j["activity"] = serializeToJson(activity_.length > 500 ? activity_[$ - 500 .. $] : activity_);
		write(path ~ ".tmp", j.toPrettyString);
		rename(path ~ ".tmp", path);
	}

	/// Deterministic demo data: 6 customers, 24 tickets in different states.
	private void seed()
	{
		customers_ = [
			Customer("acme", "ACME Corp", "enterprise", 120, "it@acme.example"),
			Customer("globex", "Globex", "team", 25, "help@globex.example"),
			Customer("initech", "Initech", "team", 40, "ops@initech.example"),
			Customer("umbrella", "Umbrella", "enterprise", 300, "admin@umbrella.example"),
			Customer("hooli", "Hooli", "free", 3, "hi@hooli.example"),
			Customer("vandelay", "Vandelay Industries", "free", 5, "art@vandelay.example"),
		];
		static immutable titles = ["Cannot log in", "Invoice is wrong", "Export is slow", "Password reset mail missing",
			"Dashboard shows no data", "Add a new user", "API returns 500", "Change billing address"];
		auto t0 = now;
		foreach (i; 0 .. 24)
		{
			Ticket t;
			t.id = nextId++;
			t.title = titles[i % titles.length];
			t.customer = customers_[(i * 5) % customers_.length].id;
			t.status = i < 9 ? "open" : i < 13 ? "pending" : i < 20 ? "solved" : "closed";
			t.priority = priorities[(i * 3) % priorities.length];
			t.assignee = i % 3 == 0 ? "" : i % 3 == 1 ? "alice" : "bob";
			t.created = t0 - (i + 1) * 5 * 3600;           // spread over the last days
			t.due = t.created + (t.priority == "urgent" ? 4 : t.priority == "high" ? 12 : 48) * 3600;
			t.updated = t.created + 1800;
			if (i % 4 == 0)
				t.comments = [Comment("alice", "Asked the customer for a screenshot.", t.created + 3600)];
			tickets_ ~= t;
			activity_ ~= Activity(t.created, "system", "opened **#" ~ idText(t.id) ~ "** " ~ escapeMarkdown(t.title), "info");
		}
	}
}

/// "#0007"-style ids.
string idText(int id)
{
	import std.format : format;
	return format("%04d", id);
}

// ------------------------------------------------ the process-wide store

private __gshared Store g_store;

/// The store of this process: `HELPDESK_DATA` (env) or data/helpdesk.json.
Store store()
{
	import streamlitd : cacheResource;
	return g_store !is null ? g_store : cacheResource!openStore(dataPath());
}

private Store openStore(string path) { return new Store(path); }

private string dataPath()
{
	import std.process : environment;
	return environment.get("HELPDESK_DATA", "data/helpdesk.json");
}

/// Tests: use this store instead.
void useStore(Store s) { g_store = s; }
