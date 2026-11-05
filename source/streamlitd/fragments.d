/// Partial reruns: `st.fragment`, `st.dialog`, and the `st.status` container.
module streamlitd.fragments;

import vibe.data.json;
import streamlitd.delta : St;
import streamlitd.util;

/// Handle returned by `st.status`: a container (use it like `st`) whose label/state can change.
final class StatusContainer
{
	/// The container; `alias this` lets you call `s.write(...)` or `with (s) { ... }`.
	St container;
	alias container this;
	private int[] path;
	private string label_, state_;
	private bool expanded_;

	package this(St c, int[] path, string label, string state, bool expanded)
	{
		container = c;
		this.path = path;
		label_ = label;
		state_ = state;
		expanded_ = expanded;
	}

	/// Change label, state ("running", "complete", "error") and/or expansion (-1 = keep, 0/1).
	void update(string label = null, string state = null, int expanded = -1)
	{
		if (label !is null) label_ = label;
		if (state !is null) state_ = state;
		if (expanded >= 0) expanded_ = expanded != 0;
		container.sess.checkInterrupt();
		container.sess.sendDelta(path, jo("kind", "block", "block", "status", "label", label_, "state", state_,
			"expanded", expanded_, "update", true));
	}
}

/// Fragment-related elements mixed into `St`.
mixin template FragmentElements()
{
	/// `st.fragment`: the body reruns on its own when a widget inside it changes, without
	/// rerunning the whole app. `runEvery` (seconds) reruns it periodically (live dashboards).
	/// Pass a lambda `(St f) { ... }`; for a named function use `toDelegate(&fn)`.
	void fragment(void delegate(St) body_, double runEvery = 0, string key = null)
	{
		auto blk = emitBlock("fragment", jo("runEvery", runEvery));
		auto fid = key.length ? "fk:" ~ key : "f:" ~ pathKey(blk.path);
		sess.registerFragment(fid, body_, blk.path.dup, formId, runEvery);
		blk.fragmentId = fid;
		body_(blk);
	}


	/// `st.dialog`: shows a modal dialog. Its widgets rerun only the dialog. The dialog stays
	/// open while it reruns and closes on the next full rerun in which it is not opened again
	/// (e.g. after `st.rerun()`), or when the user dismisses it.
	void dialog(string title, void delegate(St) body_, string width = "small", bool dismissible = true,
		string key = null)
	{
		auto overlay = new St(sess, [3]);
		auto blk = overlay.emitBlock("dialog", jo("title", title, "width", width, "dismissible", dismissible));
		auto fid = "d:" ~ (key.length ? key : title);
		sess.registerFragment(fid, body_, blk.path.dup, null, 0);
		blk.fragmentId = fid;
		body_(blk);
	}


	/// `st.status`: an expandable container showing the state of a long task.
	StatusContainer status(string label, bool expanded = false, string state = "running")
	{
		auto c = emitBlock("status", jo("label", label, "state", state, "expanded", expanded));
		return new StatusContainer(c, c.path.dup, label, state, expanded);
	}
}
