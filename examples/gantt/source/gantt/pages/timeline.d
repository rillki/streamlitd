/// The Gantt chart: phases and tasks on a calendar, milestones as diamonds, colours by status,
/// scheduling problems listed above. Click a bar to edit it, an empty day to add a task there.
module gantt.pages.timeline;

import core.time : days;
import std.conv : to;
import std.datetime : Date;
import streamlitd;
import gantt.store;
import gantt.ui;

void timelinePage(St st)
{
	st.title("Website relaunch");
	st.fragment((St f) {
		auto s = store;
		auto d = today;
		auto problems = s.conflicts;
		if (problems.length)
			with (f.expander("⚠️ " ~ problems.length.to!string ~ (problems.length == 1 ? " scheduling problem" : " scheduling problems"), true))
				foreach (c; problems)
					warning("**" ~ escapeMarkdown(c.task.name) ~ "** starts " ~ c.task.start ~ ", before **" ~ escapeMarkdown(c.dependency.name)
						~ "** ends (" ~ c.dependency.end ~ ").");
		auto c = f.columns([2.0, 1, 4]);
		auto unit = c[0].segmentedControl("Scale", ["day", "week"], 1, key: "scale", required: true);
		if (c[1].button("Add task", icon: "➕"))
			st.session["new-task"] = d.toISOExtString ~ "|";
		GridRow[] rows;
		GridItem[] items;
		chartData(s, d, rows, items);
		auto span = s.span;
		auto ev = f.calendarGrid(rows, items, span[0] - 3.days, span[1] + 7.days, unit: unit, key: "gantt", today: d,
			summaryLabel: "Progress", expanded: 1, height: 640, focus: st.queryParams.get("task"));
		f.legend([LegendItem("Done", "success"), LegendItem("Under way", "info"), LegendItem("Behind", "warning"),
			LegendItem("Late", "error"), LegendItem("Not started", "muted"), LegendItem("Milestone", "muted", "diamond")]);

		if (ev.kind == "item")
			st.session["edit-task"] = ev.item;
		// an empty day: a new task starting there, in the row's phase
		if (ev.kind == "cell")
		{
			auto phase = s.task(ev.row).phase;
			st.session["new-task"] = ev.date.toISOExtString ~ "|" ~ (phase.length ? phase : ev.row);
		}

		auto edit = st.session.get!string("edit-task", null);
		if (edit.length && s.task(edit).id.length)
			taskDialog(st, s, s.task(edit), "edit-task");
		auto add = st.session.get!string("new-task", null);
		if (add.length)
		{
			import std.string : split;
			auto parts = add.split("|");
			auto start = Date.fromISOExtString(parts[0]);
			GTask t;
			t.phase = parts.length > 1 ? parts[1] : null;
			t.start = start.toISOExtString;
			t.end = (start + 4.days).toISOExtString;
			t.assignee = people[0];
			taskDialog(st, s, t, "new-task");
		}
	}, refreshOn: topic, key: "timeline");
}
