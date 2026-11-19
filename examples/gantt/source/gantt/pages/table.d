/// The tasks as a table: grouped by phase, progress bars, late tasks highlighted; a CSV export.
module gantt.pages.table;

import std.algorithm : canFind, filter, map;
import std.array : array, join;
import std.conv : to;
import streamlitd;
import gantt.store;
import gantt.ui;

alias C = ColumnConfig;

DataFrame taskFrame(Store s)
{
	string[string] phaseName, taskName;
	foreach (p; s.phases)
		phaseName[p.id] = p.name;
	auto ts = s.tasks;
	foreach (t; ts)
		taskName[t.id] = t.name;
	auto d = today;
	Json[][] rows;
	foreach (t; ts)
		rows ~= [Json(t.id), Json(phaseName.get(t.phase, "—")), Json((t.milestone ? "◆ " : "") ~ t.name), Json(t.start),
			Json(t.end), Json(t.days_), Json(t.progress), Json(t.assignee), Json(statusOf(t, d)),
			Json(t.dependsOn.map!(x => taskName.get(x, x)).join(", "))];
	return DataFrame.fromRows(["id", "phase", "task", "start", "end", "days", "progress", "assignee", "status", "after"], rows);
}

void tablePage(St st)
{
	st.title("Tasks");
	st.fragment((St f) {
		auto s = store;
		auto df = taskFrame(s);
		// a click on a row opens it in the editor (onChange: only when the selection changes, so the
		// dialog stays closed after it was closed, even though the row is still selected)
		f.dataframe(df, hideIndex: true, groupBy: ["phase"], expanded: 1, onSelect: "rerun", rowKey: "id",
			key: "task-table", maxHeight: 520, onChange: {
				auto sel = st.session.get!TableSelection("task-table");
				if (sel.keys.length)
					st.session["edit-task"] = sel.keys[0].get!string;
			},
			columnConfig: [
				"id": C.hide(),
				"task": C.text("Task", pinned: true, width: "large"),
				"start": C.date("Start", format: "DD.MM.YYYY"),
				"end": C.date("End", format: "DD.MM.YYYY"),
				"days": C.number("Days", format: "%d"),
				"progress": C.progress("Progress", min: 0, max: 1, format: "percent"),
				"assignee": C.text("Owner", width: "small"),
				"status": C.text("Status", width: "small"),
				"after": C.text("After", help: "Tasks it depends on"),
			],
			totals: ["task": "count", "days": "sum", "progress": "mean"],
			cellStyle: (size_t r, string col, Json v) {
				if (col != "status" && col != "end") return null;
				auto status = df.cell(r, "status").get!string;
				if (status == "late") return col == "end" ? "text:error bold" : "bg:error";
				if (status == "behind" && col == "status") return "bg:warning";
				if (status == "done" && col == "status") return "bg:success";
				return null;
			});
		f.caption("Click a task to edit it.");
		auto edit = st.session.get!string("edit-task", null);
		if (edit.length && s.task(edit).id.length)
			taskDialog(st, s, s.task(edit), "edit-task");
	}, refreshOn: topic, key: "table");
	st.downloadButton("Export CSV", () => taskFrame(store).drop("id").toCsv(',', true), "tasks.csv", "text/csv", icon: "⬇️");
}
