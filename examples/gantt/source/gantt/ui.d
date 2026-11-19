/// Shared parts of the Gantt pages: the chart's rows and bars, the task dialog.
module gantt.ui;

import core.time : days;
import std.algorithm : canFind, countUntil, filter, map, sum;
import std.array : array;
import std.conv : to;
import std.datetime : Date;
import std.string : strip;
import streamlitd;
import gantt.store;

/// Colour of a task: done green, late red, behind orange, under way blue, not started grey.
string statusOf(GTask t, Date d)
{
	if (t.done) return "done";
	if (t.late(d)) return "late";
	if (d >= t.startDate && t.progress + 0.15 < t.expected(d)) return "behind";
	if (d >= t.startDate) return "under way";
	return "not started";
}

string colorOf(string status)
{
	switch (status)
	{
		case "done": return "success";
		case "late": return "error";
		case "behind": return "warning";
		case "under way": return "info";
		default: return "muted";
	}
}

/// Rows (phases, their tasks under them) and bars of the chart.
void chartData(Store s, Date d, out GridRow[] rows, out GridItem[] items)
{
	auto ts = s.tasks;
	foreach (p; s.phases)
	{
		auto mine = ts.filter!(t => t.phase == p.id).array;
		double total = mine.map!(t => cast(double) t.days_).sum;
		double done = 0, expected = 0;
		foreach (t; mine)
		{
			done += t.progress * t.days_;
			expected += t.expected(d) * t.days_;
		}
		rows ~= GridRow(p.id, p.name, null, total ? (done / total * 100).to!int.to!string ~ "% done" : "empty",
			total ? done / total : double.nan, total ? expected / total : double.nan);
		foreach (t; mine)
			rows ~= GridRow(t.id, t.name, p.id, t.assignee, t.milestone ? double.nan : t.progress,
				t.milestone ? double.nan : t.expected(d));
	}
	foreach (t; ts)
	{
		auto st = statusOf(t, d);
		auto label = t.name ~ " · " ~ t.assignee ~ " · " ~ st;
		if (t.milestone)
			items ~= GridItem(t.id, t.id, t.startDate, Date.init, label, double.nan, "diamond", colorOf(st), !t.done);
		else
			items ~= GridItem(t.id, t.id, t.startDate, t.endDate, label ~ " · " ~ (t.progress * 100).to!int.to!string ~ "%",
				double.nan, null, colorOf(st), st == "not started");
	}
}

/// The task dialog: edit an existing task (`t.id` set) or add one. Closing it clears `sessionKey`.
void taskDialog(St st, Store s, GTask t, string sessionKey)
{
	auto isNew = !t.id.length;
	void close() { st.session.remove(sessionKey); st.session["confirm-delete"] = false; }
	st.dialog(isNew ? "New task" : "Edit task", (St d) {
		auto k = isNew ? "-new" : "-" ~ t.id;
		// the pickers offer only dates the store accepts (it checks again)
		auto earliest = today - (365 * (maxYears - 1)).days, latest = today + (365 * (maxYears - 1)).days;
		auto name = d.textInput("Name", t.name, maxChars: maxName, key: "name" ~ k);
		auto phases = s.phases;
		auto pnames = phases.map!(p => p.name).array;
		auto pi = phases.countUntil!(p => p.id == t.phase);
		auto c = d.columns(2);
		auto phase = c[0].selectbox("Phase", pnames, pi < 0 ? 0 : pi, key: "phase" ~ k);
		auto who = c[1].selectbox("Assignee", people.dup, people.countUntil(t.assignee) < 0 ? 0 : people.countUntil(t.assignee),
			key: "who" ~ k);
		auto milestone = d.checkbox("Milestone (one day)", t.milestone, key: "ms" ~ k);
		DateRange when;
		if (milestone)
		{
			auto day = d.dateInput("Day", t.startDate, earliest, latest, key: "day" ~ k);
			when = DateRange(day, day);
		}
		else
			when = d.dateRangeInput("Dates", DateRange(t.startDate, t.endDate), earliest, latest, key: "dates" ~ k);
		auto progress = milestone ? (d.checkbox("Reached", t.done, key: "reached" ~ k) ? 100 : 0)
			: d.slider("Progress", 0, 100, cast(int) (t.progress * 100), 5, key: "progress" ~ k, format: "%d%%");
		auto others = s.tasks.filter!(x => x.id != t.id).array;
		// options carry the id: two tasks may have the same name
		static string option(GTask x) { return x.name ~ " · " ~ x.id; }
		auto onames = others.map!option.array;
		auto deps = d.multiselect("Depends on", onames, others.filter!(x => t.dependsOn.canFind(x.id)).map!option.array,
			key: "deps" ~ k, placeholder: "Nothing");
		// warn right away when the dates clash with what it depends on
		foreach (x; others)
			if (deps.canFind(option(x)) && when.start != Date.init && when.start <= x.endDate)
				d.warning("Starts before “" ~ escapeMarkdown(x.name) ~ "” ends (" ~ x.end ~ ").", icon: "⚠️");
		auto b = d.columns([1.0, 1, 2]);
		if (b[0].button(isNew ? "Add" : "Save", type: "primary", key: "save" ~ k))
		{
			if (!name.strip.length)
				d.error("Give the task a name.");
			else if (when.start == Date.init || when.end == Date.init)
				d.error("Choose the dates.");
			else
			{
				auto n = t;
				n.name = name.strip;
				n.phase = phases[pnames.countUntil(phase)].id;
				n.assignee = who;
				n.milestone = milestone;
				n.start = when.start.toISOExtString;
				n.end = when.end.toISOExtString;
				n.progress = progress / 100.0;
				n.dependsOn = others.filter!(x => deps.canFind(option(x))).map!(x => x.id).array;
				if (auto problem = s.problemOf(n))
					d.error(problem);
				else
				{
					s.put(n);
					close();
					st.toast((isNew ? "Added " : "Saved ") ~ escapeMarkdown(n.name));
					st.rerun();
				}
			}
		}
		if (!isNew && b[1].button("Delete…", key: "delete" ~ k))
			st.session["confirm-delete"] = true;
		if (!isNew && st.session.get!bool("confirm-delete", false))
			st.dialog("Delete “" ~ escapeMarkdown(t.name) ~ "”?", (St c2) {
				c2.write("Tasks that depend on it lose that dependency.");
				auto yn = c2.columns(2);
				if (yn[0].button("Delete", type: "primary", key: "delete-yes"))
				{
					s.remove(t.id);
					close();
					st.rerun();
				}
				if (yn[1].button("Keep it", key: "delete-no"))
				{
					st.session["confirm-delete"] = false;
					st.rerun();
				}
			}, key: "confirm-delete", onDismiss: { st.session["confirm-delete"] = false; });
	}, width: "medium", key: "task", onDismiss: &close);
}
