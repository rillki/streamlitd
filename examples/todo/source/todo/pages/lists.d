/// Managing lists: add one, delete one (with its tasks) after a confirmation.
module todo.pages.lists;

import std.algorithm : count, countUntil;
import std.conv : to;
import std.string : strip;
import streamlitd;
import todo.store;
import todo.ui;

void listsPage(St st)
{
	auto user = me(st);
	auto s = store;
	auto b = s.board(user);
	st.title("Lists");
	auto fm = st.form("new-list", clearOnSubmit: true);
	auto c = fm.columns([1.0, 4]);
	auto icon = c[0].textInput("Icon", "📝", maxChars: 4, key: "list-icon");
	auto name = c[1].textInput("Name", maxChars: maxListName, key: "list-name", placeholder: "e.g. Shopping");
	if (fm.formSubmitButton("Add list") && name.strip.length)
	{
		try
		{
			s.addList(user, name.strip, icon.strip);
			st.rerun();
		}
		catch (LimitError e)
			st.error(e.msg);
	}
	foreach (i, l; b.lists)
	{
		auto open = b.tasks.count!(t => t.list == l.id && !t.done);
		auto row = st.columns([6.0, 1]);
		row[0].markdown(escapeMarkdown(l.icon) ~ " **" ~ escapeMarkdown(l.name) ~ "** · " ~ open.to!string ~ " open");
		if (i > 0 && row[1].button("Delete", key: "del-list-" ~ l.id))
			st.session["delete-list"] = l.id;
	}
	auto del = st.session.get!string("delete-list", null);
	auto at = b.lists.countUntil!(l => l.id == del);
	if (at > 0)
		confirmDelete(st, s, user, b, b.lists[at]);
}

// its own function: the dialog's body reruns alone later, and must not see a loop variable that
// has moved on to another list since
private void confirmDelete(St st, Store s, string user, Board b, TaskList l)
{
	st.dialog("Delete “" ~ escapeMarkdown(l.name) ~ "”?", (St d) {
		d.warning("Its " ~ b.tasks.count!(t => t.list == l.id).to!string ~ " tasks are deleted too.");
		if (d.button("Delete the list", type: "primary"))
		{
			s.removeList(user, l.id);
			st.session["delete-list"] = "";
			st.rerun();
		}
	}, key: "delete-list", onDismiss: { st.session["delete-list"] = ""; });
}
