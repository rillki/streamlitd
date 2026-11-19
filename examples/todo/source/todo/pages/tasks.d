/// A list of tasks (or a view across lists: today, upcoming): quick add, filters, done
/// checkboxes, pages, an edit dialog with a nested delete confirmation, and bulk actions on
/// selected rows.
module todo.pages.tasks;

import core.time : days;
import std.algorithm : canFind, filter, map, sort, uniq, countUntil, any;
import std.array : array, join;
import std.conv : to;
import std.datetime : Date;
import std.string : strip, toLower;
import streamlitd;
import todo.store;
import todo.ui;

/// Which tasks a page shows: a list's id, or "today" / "upcoming".
package(todo) Task[] inScope(Board b, string scope_, Date t)
{
	switch (scope_)
	{
		case "today": return b.tasks.filter!(x => !x.done && x.due.length && x.dueDate <= t).array;
		case "upcoming": return b.tasks.filter!(x => !x.done && x.due.length && x.dueDate > t).array;
		default: return b.tasks.filter!(x => x.list == scope_).array;
	}
}

/// Filter and order: open first, then by due date (none last), priority, id.
package(todo) Task[] shown(Task[] ts, string show, string[] tags, string q)
{
	auto query = q.strip.toLower;
	auto r = ts.filter!(x => (show == "All" || (show == "Done") == x.done)
		&& (!tags.length || tags.any!(g => x.tags.canFind(g)))
		&& (!query.length || x.title.toLower.canFind(query) || x.notes.toLower.canFind(query))).array;
	static int rank(string p) { return p == "high" ? 0 : p == "normal" ? 1 : 2; }
	r.sort!((a, b) {
		if (a.done != b.done) return !a.done;
		auto da = a.due.length ? a.due : "9999", db = b.due.length ? b.due : "9999";
		if (da != db) return da < db;
		if (rank(a.priority) != rank(b.priority)) return rank(a.priority) < rank(b.priority);
		return a.id < b.id;
	});
	return r;
}

enum pageSize = 8;

void taskView(St st, string scope_, string title)
{
	auto user = me(st);
	auto s = store;
	auto lists = s.board(user).lists;
	st.title(title); // list names are escaped by the caller

	// quick add: the form clears itself after Add
	auto addTo = lists.canFind!(l => l.id == scope_) ? scope_ : lists[0].id;
	auto fm = st.form("quick-add", clearOnSubmit: true);
	auto text = fm.textInput("New task", maxChars: maxTitle + 100, key: "quick-text", placeholder: "Call Anna #phone !high ^tomorrow",
		help: "#tag adds a tag, !high or !low sets the priority, ^today, ^tomorrow or ^2026-12-01 a due date");
	if (fm.formSubmitButton("Add") && text.strip.length)
	{
		auto t = parseQuick(text);
		t.list = addTo;
		if (scope_ == "today" && !t.due.length)
			t.due = today.toISOExtString;
		if (t.title.length)
		{
			try
			{
				s.add(user, t);
				st.toast("Added “" ~ escapeMarkdown(t.title) ~ "”", "✅");
			}
			catch (LimitError e)
				st.error(e.msg);
		}
	}

	// the list itself reruns alone, and when the same person changes something in another tab
	st.fragment((St f) { listBody(st, f, s, user, scope_); }, refreshOn: topicOf(user), key: "tasks-" ~ scope_);
}

private void listBody(St st, St f, Store s, string user, string scope_)
{
	auto b = s.board(user);
	auto t = today;
	auto all = inScope(b, scope_, t);
	auto tags = all.map!(x => x.tags).join.sort.uniq.array;
	auto c = f.columns([2.0, 3, 2]);
	auto show = c[0].segmentedControl("Show", ["Open", "Done", "All"], 0, key: "show", required: true);
	auto pick = tags.length ? c[1].pillsMulti("Tags", tags, key: "tags-" ~ scope_) : null;
	auto q = c[2].textInput("Search", key: "search-" ~ scope_, placeholder: "Title or notes");
	auto list = shown(all, show, pick, q);
	auto bulk = f.toggle("Select several", key: "bulk");

	if (!list.length)
	{
		if (!all.length)
			f.emptyState("Nothing here yet", "Add a task above.", "🌱");
		else
			f.emptyState("No tasks match", "Change the filters above.", "🔍");
		return;
	}
	if (bulk)
		bulkActions(st, f, s, user, list, b.lists);
	else
	{
		auto page = list.length > pageSize ? f.pagination(list.length, pageSize, key: "page-" ~ scope_) : 1;
		auto from = (page - 1) * pageSize;
		auto to_ = from + pageSize < list.length ? from + pageSize : list.length;
		foreach (x; list[from .. to_])
			taskRow(st, f, s, user, x, scope_ != x.list ? b.lists : null);
		f.caption(list.length.to!string ~ (list.length == 1 ? " task" : " tasks"));
	}
	editDialog(st, s, user, b);
}

/// A task: its done checkbox (the title is the label), the details, an edit button.
private void taskRow(St st, St f, Store s, string user, Task x, TaskList[] showList)
{
	auto r = f.columns([8.0, 1]);
	// the key carries the stored state: a change from elsewhere (bulk, other tab) makes a fresh checkbox
	// the label is Markdown: the title is escaped, only the strike-through is ours
	r[0].checkbox(x.done ? "~~" ~ escapeMarkdown(x.title) ~ "~~" : escapeMarkdown(x.title), x.done, key: "done-" ~ x.id.to!string ~ (x.done ? "-1" : "-0"),
		onChange: toggler(s, user, x));
	auto meta = metaLine(x, today);
	if (showList.length)
	{
		auto i = showList.countUntil!(l => l.id == x.list);
		if (i >= 0)
			meta = escapeMarkdown(showList[i].icon ~ " " ~ showList[i].name) ~ (meta.length ? " · " ~ meta : "");
	}
	if (meta.length)
		r[0].caption(meta);
	if (r[1].button("Edit", key: "edit-" ~ x.id.to!string, icon: "✏️"))
		st.session["editing"] = x.id;
}

// a function, so each checkbox gets its own task (closures in a foreach share the loop variable)
private void delegate() toggler(Store s, string user, Task x)
{
	return () { s.update(user, [x.id], (ref Task t) { t.done = !x.done; }); };
}

private void bulkActions(St st, St f, Store s, string user, Task[] list, TaskList[] lists)
{
	Json[][] rows;
	foreach (x; list)
		rows ~= [Json(x.id), Json(x.done), Json(x.title), Json(x.due.length ? x.due : null), Json(x.priority),
			Json(x.tags.join(", "))];
	alias C = ColumnConfig;
	auto sel = f.dataframe(DataFrame.fromRows(["id", "done", "title", "due", "priority", "tags"], rows), hideIndex: true,
		onSelect: "rerun", selectionMode: "multi-row", rowKey: "id", key: "bulk-table", maxHeight: 380,
		columnConfig: ["id": C.hide(), "done": C.checkbox("Done", width: "small"), "title": C.text("Task", width: "large"),
			"due": C.date("Due", format: "DD.MM.YYYY"), "priority": C.text("Priority", width: "small"), "tags": C.text("Tags")],
		cellStyle: (size_t r, string col, Json v) => col == "due" && v.type == Json.Type.string
			&& !list[r].done && list[r].dueDate < today ? "text:error bold" : null);
	auto ids = sel.keys.map!(k => cast(int) k.get!long).array;
	auto c = f.columns([1.2, 1.2, 2, 1.2, 1.4]);
	auto none = ids.length == 0;
	if (c[0].button("Complete", disabled: none, type: "primary"))
	{
		s.update(user, ids, (ref Task t) { t.done = true; });
		st.toast("Completed " ~ ids.length.to!string, "✅");
	}
	if (c[1].button("Reopen", disabled: none))
		s.update(user, ids, (ref Task t) { t.done = false; });
	auto names = lists.map!(l => l.name).array;
	auto target = c[2].selectbox("Move to", names, 0, key: "move-to", labelVisibility: "collapsed", disabled: none);
	if (c[3].button("Move", disabled: none))
	{
		auto id = lists[names.countUntil(target)].id;
		s.update(user, ids, (ref Task t) { t.list = id; });
		st.toast("Moved to " ~ target);
	}
	if (c[4].button("Delete…", disabled: none))
		st.session["confirm-delete"] = true;
	if (!none && st.session.get!bool("confirm-delete", false))
		st.dialog("Delete " ~ ids.length.to!string ~ (ids.length == 1 ? " task?" : " tasks?"), (St d) {
			d.write("This can't be undone.");
			auto b = d.columns(2);
			if (b[0].button("Delete", type: "primary", key: "bulk-delete-yes"))
			{
				s.removeTasks(user, ids);
				st.session["confirm-delete"] = false;
				st.resetWidgets("bulk-table");
				st.rerun();
			}
			if (b[1].button("Cancel", key: "bulk-delete-no"))
			{
				st.session["confirm-delete"] = false;
				st.rerun();
			}
		}, key: "bulk-delete", onDismiss: { st.session["confirm-delete"] = false; });
	f.caption(ids.length ? ids.length.to!string ~ " selected" : "Select tasks with the checkboxes; Shift-click selects a range.");
}

private void editDialog(St st, Store s, string user, Board b)
{
	auto id = st.session.get!int("editing", 0);
	auto i = b.tasks.countUntil!(t => t.id == id);
	if (!id || i < 0)
		return;
	auto x = b.tasks[i];
	void close() { st.session["editing"] = 0; st.session["confirm-remove"] = false; }
	st.dialog("Edit task", (St d) {
		auto k = "-" ~ x.id.to!string;
		auto title = d.textInput("Title", x.title, maxChars: maxTitle, key: "e-title" ~ k);
		auto notes = d.textArea("Notes", x.notes, height: 90, maxChars: maxNotes, key: "e-notes" ~ k, placeholder: "Details, links, …");
		auto c = d.columns(2);
		auto hasDue = c[0].checkbox("Has a due date", x.due.length > 0, key: "e-has-due" ~ k);
		Date due;
		if (hasDue)
			due = c[0].dateInput("Due", x.due.length ? x.dueDate : today, key: "e-due" ~ k);
		auto prio = c[1].segmentedControl("Priority", priorities.dup, priorities.dup.countUntil(x.priority), key: "e-prio" ~ k,
			required: true);
		auto allTags = b.tasks.map!(t => t.tags).join.sort.uniq.array;
		auto tags = d.tagsInput("Tags", x.tags, allTags, 10, key: "e-tags" ~ k,
			help: "Letters, digits, - and _; other characters are dropped");
		auto names = b.lists.map!(l => l.name).array;
		auto li = b.lists.countUntil!(l => l.id == x.list);
		auto listName = d.selectbox("List", names, li < 0 ? 0 : li, key: "e-list" ~ k);
		auto bt = d.columns([1.0, 1, 2]);
		if (bt[0].button("Save", type: "primary", key: "e-save"))
		{
			if (!title.strip.length)
				d.error("The title must not be empty.");
			else
			{
				auto listId = b.lists[names.countUntil(listName)].id;
				s.update(user, [x.id], (ref Task t) {
					t.title = title.strip; t.notes = notes; t.due = hasDue ? due.toISOExtString : null;
					t.priority = prio; t.tags = tags.map!cleanTag.filter!(g => g.length > 0).array.sort.uniq.array;
					t.list = listId;
				});
				close();
				st.rerun();
			}
		}
		if (bt[1].button("Delete…", key: "e-delete"))
			st.session["confirm-remove"] = true;
		if (st.session.get!bool("confirm-remove", false))
			st.dialog("Delete “" ~ escapeMarkdown(x.title) ~ "”?", (St c2) {
				auto yn = c2.columns(2);
				if (yn[0].button("Delete", type: "primary", key: "e-delete-yes"))
				{
					s.removeTasks(user, [x.id]);
					close();
					st.rerun();
				}
				if (yn[1].button("Keep it", key: "e-delete-no"))
				{
					st.session["confirm-remove"] = false;
					st.rerun();
				}
			}, key: "confirm-remove", onDismiss: { st.session["confirm-remove"] = false; });
	}, key: "edit-task", onDismiss: &close);
}
