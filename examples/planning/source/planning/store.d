/// The data of the planning app: suppliers, brands, a monthly purchase plan and the actual
/// purchases ("fact"), deliveries. Shared by all users, kept in a JSON file, written atomically.
module planning.store;

import core.sync.mutex : Mutex;
import std.algorithm : canFind, countUntil, map, sum;
import std.array : array;
import std.conv : to;
import std.datetime : Clock, Date;
import std.format : format;
import vibe.data.json;
import streamlitd : cacheResource, refreshFragments;

/// Topic of `refreshFragments`: pages that show plan data listen to it.
enum topic = "planning";

/// Largest amount of one plan cell, and the most brands / the longest name.
enum maxAmount = 1e9, maxBrands = 500, maxName = 100;

/// Is `v` an amount the plan may hold?
bool validAmount(double v)
{
	import std.math : isFinite;
	return isFinite(v) && v >= 0 && v <= maxAmount;
}

struct Supplier
{
	string id;
	string name;
	string manager;
}

struct Brand
{
	string id;
	string supplier;   /// Supplier.id
	string name;
	double[12] plan = 0;
	double[12] fact = 0;   /// filled for closed months
}

struct Delivery
{
	string id;
	string brand;      /// Brand.id
	Date date;
	double amount;
	bool delivered;
}

/// One change of the plan: a cell, a new or a removed brand.
struct PlanChange
{
	string kind;       /// "changed", "added", "removed"
	string supplier;   /// name
	string brand;      /// name
	int month;         /// 1..12 ("changed")
	double before = 0;
	double after = 0;
}

private __gshared Date g_today;

/// Today (fixed in tests with `useToday`, or by the env variable `PLANNING_TODAY=YYYY-MM-DD`).
Date today()
{
	import std.process : environment;
	if (g_today != Date.init)
		return g_today;
	if (auto s = environment.get("PLANNING_TODAY"))
		return Date.fromISOExtString(s);
	return cast(Date) Clock.currTime;
}

void useToday(Date d) { g_today = d; }

/// Months before the current one are closed: their fact is known, the plan can't change.
bool isClosed(int month) { return month < today.month; }

/// "Jan" .. "Dec".
immutable monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

final class Store
{
	private Mutex lock;
	private string path;
	private bool push;
	private Supplier[] suppliers_;
	private Brand[] brands_;
	private Delivery[] deliveries_;
	private int nextId = 1;
	private long version_;   /// +1 on every change of the plan

	/// Load `path`, or seed demo data when it doesn't exist (`path` null: memory only).
	this(string path, bool push = true)
	{
		import std.file : exists, readText;
		lock = new Mutex;
		this.path = path;
		this.push = push;
		if (path.length && path.exists)
		{
			auto j = parseJsonString(readText(path));
			suppliers_ = deserializeJson!(Supplier[])(j["suppliers"]);
			brands_ = deserializeJson!(Brand[])(j["brands"]);
			deliveries_ = deserializeJson!(Delivery[])(j["deliveries"]);
			nextId = j["nextId"].get!int;
			version_ = j["version"].get!long;
		}
		else
			seed();
	}

	Supplier[] suppliers() { synchronized (lock) return suppliers_.dup; }
	Brand[] brands() { synchronized (lock) return brands_.dup; }
	Delivery[] deliveries() { synchronized (lock) return deliveries_.dup; }
	long version_no() { synchronized (lock) return version_; }

	string supplierName(string id)
	{
		synchronized (lock)
			foreach (s; suppliers_)
				if (s.id == id)
					return s.name;
		return id;
	}

	Brand brand(string id)
	{
		synchronized (lock)
			foreach (b; brands_)
				if (b.id == id)
					return b;
		return Brand.init;
	}

	/// Differences between the stored plan and `next` (brands matched by supplier and name).
	PlanChange[] diff(Brand[] next)
	{
		PlanChange[] r;
		auto cur = brands;
		auto matched = matchBrands(cur, next);
		bool[string] seen;
		foreach (i, b; next)
		{
			if (auto o = matched[i])
			{
				seen[o.id] = true;
				if (o.name != b.name || o.supplier != b.supplier)
					r ~= PlanChange("renamed", supplierName(b.supplier), supplierName(o.supplier) ~ " · " ~ o.name ~ " → "
						~ supplierName(b.supplier) ~ " · " ~ b.name);
				foreach (m; 0 .. 12)
					if (o.plan[m] != b.plan[m])
						r ~= PlanChange("changed", supplierName(b.supplier), b.name, m + 1, o.plan[m], b.plan[m]);
			}
			else
				r ~= PlanChange("added", supplierName(b.supplier), b.name, 0, 0, b.plan[].sum);
		}
		foreach (b; cur)
			if (b.id !in seen)
				r ~= PlanChange("removed", supplierName(b.supplier), b.name, 0, b.plan[].sum, 0);
		return r;
	}

	/// For each brand of `next`, the stored brand it is: by id (so renaming or moving a brand to
	/// another supplier keeps its fact and deliveries), else by supplier and name (rows without
	/// an id, e.g. typed again). A stored brand is matched at most once.
	private static Brand*[] matchBrands(Brand[] cur, Brand[] next)
	{
		Brand*[string] byId, byKey;
		foreach (ref b; cur)
		{
			byId[b.id] = &b;
			byKey[b.supplier ~ "\x1f" ~ b.name] = &b;
		}
		bool[string] used;
		auto r = new Brand*[next.length];
		foreach (i, b; next)
			if (b.id.length)
				if (auto p = b.id in byId)
					if ((*p).id !in used)
					{
						r[i] = *p;
						used[(*p).id] = true;
					}
		foreach (i, b; next)
			if (r[i] is null && !b.id.length)
				if (auto p = (b.supplier ~ "\x1f" ~ b.name) in byKey)
					if ((*p).id !in used)
					{
						r[i] = *p;
						used[(*p).id] = true;
					}
		return r;
	}

	/// Replace the plan, if nobody else saved since `baseVersion`; false otherwise. Facts and
	/// deliveries of kept brands stay; closed months keep their stored plan.
	bool savePlan(Brand[] next, long baseVersion)
	{
		import std.algorithm : all;
		// checked here too: the editor's limits are the browser's, a client may send anything
		if (next.length > maxBrands || !next.all!(b => b.plan[].all!validAmount && b.name.length && b.name.length <= maxName * 4))
			throw new Exception("invalid plan");
		synchronized (lock)
		{
			if (baseVersion != version_)
				return false;
			auto matched = matchBrands(brands_, next);
			Brand[] r;
			foreach (i, b; next)
			{
				auto nb = b;
				if (auto o = matched[i])
				{
					nb.id = o.id;
					nb.fact = o.fact;
					foreach (m; 0 .. 12)
						if (isClosed(m + 1))
							nb.plan[m] = o.plan[m];
				}
				else
					nb.id = "b" ~ (nextId++).to!string;
				r ~= nb;
			}
			bool[string] keep;
			foreach (b; r)
				keep[b.id] = true;
			brands_ = r;
			Delivery[] ds;
			foreach (d; deliveries_)
				if (d.brand in keep)
					ds ~= d;
			deliveries_ = ds;
			version_++;
			save();
		}
		changed();
		return true;
	}

	/// Set single plan cells (the import): brand by supplier id and name, created if new.
	void applyCells(string[3][] cells, double[] amounts)
	{
		import std.algorithm : all;
		if (cells.length != amounts.length || !amounts.all!validAmount)
			throw new Exception("invalid amounts");
		synchronized (lock)
		{
			foreach (i, c; cells)
			{
				auto sup = c[0], name = c[1];
				auto m = c[2].to!int - 1;
				auto at = brands_.countUntil!(b => b.supplier == sup && b.name == name);
				if (at < 0)
				{
					brands_ ~= Brand("b" ~ (nextId++).to!string, sup, name);
					at = brands_.length - 1;
				}
				brands_[at].plan[m] = amounts[i];
			}
			version_++;
			save();
		}
		changed();
	}

	/// Add a supplier (the import's "new supplier"); returns its id.
	string addSupplier(string name, string manager)
	{
		string id;
		synchronized (lock)
		{
			id = "s" ~ (nextId++).to!string;
			suppliers_ ~= Supplier(id, name, manager);
			save();
		}
		changed();
		return id;
	}

	/// Move a delivery or mark it delivered.
	bool updateDelivery(string id, void delegate(ref Delivery) change)
	{
		bool found;
		synchronized (lock)
		{
			foreach (ref d; deliveries_)
				if (d.id == id)
				{
					change(d);
					found = true;
				}
			if (found)
				save();
		}
		if (found)
			changed();
		return found;
	}

	/// Plan a delivery.
	Delivery addDelivery(string brand, Date date, double amount)
	{
		Delivery d;
		synchronized (lock)
		{
			d = Delivery("d" ~ (nextId++).to!string, brand, date, amount, false);
			deliveries_ ~= d;
			save();
		}
		changed();
		return d;
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
		j["suppliers"] = serializeToJson(suppliers_);
		j["brands"] = serializeToJson(brands_);
		j["deliveries"] = serializeToJson(deliveries_);
		j["nextId"] = nextId;
		j["version"] = version_;
		write(path ~ ".tmp", j.toPrettyString);
		rename(path ~ ".tmp", path);
	}

	private void seed()
	{
		suppliers_ = [
			Supplier("acme", "ACME", "Ann"),
			Supplier("globex", "Globex", "Ann"),
			Supplier("initech", "Initech", "Bob"),
			Supplier("umbrella", "Umbrella", "Bob"),
		];
		static immutable string[2][] names = [["acme", "Rocket"], ["acme", "Anvil"], ["globex", "Gizmo"],
			["globex", "Widget"], ["initech", "Stapler"], ["initech", "Printer"], ["umbrella", "Shield"]];
		auto t = today;
		foreach (i, n; names)
		{
			Brand b = Brand("b" ~ (nextId++).to!string, n[0], n[1]);
			foreach (m; 0 .. 12)
			{
				// a seasonal plan; the fact differs from it by -25 % .. +20 %, deterministically
				b.plan[m] = 100.0 * ((i % 4) + 3) * (m >= 9 ? 1.5 : 1.0);
				if (isClosed(m + 1))
					b.fact[m] = b.plan[m] * (0.75 + ((i * 7 + m * 3) % 10) * 0.05);
			}
			brands_ ~= b;
			// deliveries: three per brand around today; past ones delivered, except a few (late)
			foreach (k; 0 .. 3)
			{
				auto d = t + ((cast(int) i * 3 + k * 9 - 12)).days;
				deliveries_ ~= Delivery("d" ~ (nextId++).to!string, b.id, d, b.plan[t.month - 1] / 3,
					d < t && (i + k) % 4 != 1);
			}
		}
	}
}

private auto days(int n) { import core.time : dur; return dur!"days"(n); }

private __gshared Store g_store;

/// The shared store (`PLANNING_DATA`, default data/planning.json).
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
	return environment.get("PLANNING_DATA", "data/planning.json");
}

/// Tests: use this store instead.
void useStore(Store s) { g_store = s; }

/// "1,234".
string money(double v)
{
	import std.math : round;
	auto s = format("%,d", cast(long) round(v));
	return s;
}
