/// The yearly plan: an editable table (closed months read-only), saved after a review of the
/// changes, with a check that nobody else saved in between.
module planning.pages.plan;

import std.algorithm : map, sum;
import std.conv : to;
import streamlitd;
import planning.store;
import planning.ui;

void planPage(St st)
{
	auto s = store;
	st.title("Purchase plan " ~ today.year.to!string);
	st.caption("Months before " ~ monthNames[today.month - 1] ~ " are closed. Add a row for a new brand; "
		~ "select rows to remove them.");

	// the version this user's edits are based on
	auto current = s.version_no;
	auto base = st.session.setDefault!long("plan-base", current);
	auto edited = st.dataEditor(planFrame(s), key: "plan-editor", numRows: "dynamic", hideIndex: true, maxRows: maxBrands,
		disabled: ["id"],
		columnConfig: planColumns(s));
	string[] problems;
	auto next = brandsFrom(edited, s, problems);
	auto changes = problems.length ? null : s.diff(next);

	if (base != current)
	{
		if (!changes.length)
			st.session["plan-base"] = base = current; // nothing of ours to lose: follow along
		else
		{
			st.warning("Someone else saved the plan while you were editing. Load their version (your edits are "
				~ "dropped) and make your changes again.", icon: "⚠️");
			if (st.button("Load the latest plan"))
			{
				st.resetWidgets("plan-editor");
				st.session["plan-base"] = current;
				st.rerun();
			}
			return;
		}
	}
	foreach (p; problems)
		st.error(escapeMarkdown(p)); // problems quote what was typed

	double total = 0;
	foreach (b; next)
		total += b.plan[].sum;
	auto c = st.columns([2.0, 1, 1, 3]);
	c[0].metric("Plan for the year", money(total), border: true);
	if (c[1].button("Review & save", type: "primary", disabled: problems.length > 0 || !changes.length))
		st.session["plan-review"] = true;
	if (c[2].button("Discard", disabled: !changes.length))
	{
		st.resetWidgets("plan-editor");
		st.rerun();
	}
	if (changes.length)
		c[3].caption(changes.length.to!string ~ " unsaved change" ~ (changes.length == 1 ? "" : "s"));

	if (st.session.get!bool("plan-review", false) && changes.length)
		st.dialog("Save " ~ changes.length.to!string ~ (changes.length == 1 ? " change?" : " changes?"), (St d) {
			auto df = changesFrame(changes);
			d.dataframe(df, hideIndex: true, columnConfig: changeColumns(), cellStyle: changeStyleFor(df), maxHeight: 320);
			auto b = d.columns(2);
			if (b[0].button("Save", type: "primary", key: "review-save"))
			{
				st.session["plan-review"] = false;
				if (s.savePlan(next, base))
				{
					st.resetWidgets("plan-editor");
					st.session["plan-base"] = s.version_no;
					st.toast("Plan saved", "✅");
				}
				else
					st.session["plan-conflict"] = true;
				st.rerun();
			}
			if (b[1].button("Back to editing", key: "review-back"))
			{
				st.session["plan-review"] = false;
				st.rerun();
			}
		}, width: "large", key: "plan-review", onDismiss: { st.session["plan-review"] = false; });
	if (st.session.get!bool("plan-conflict", false))
	{
		st.session["plan-conflict"] = false;
		st.error("Not saved: the plan was changed by someone else in the meantime.");
	}

	st.downloadButton("Download plan (CSV)", () => planFrame(store).drop("id").toCsv(',', true), "plan.csv", "text/csv", icon: "⬇️");
}
