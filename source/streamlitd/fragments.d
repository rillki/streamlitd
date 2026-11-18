/// Partial reruns: `st.fragment`, `st.dialog`, and the `st.status` container.
module streamlitd.fragments;

import vibe.data.json;
import streamlitd.delta : St;
import streamlitd.util;

/// Handle returned by `st.fragment`: rerun that fragment on demand. Keep it (e.g. in
/// `st.session` or your own registry) and call `refresh()` from anywhere: a file watcher, a queue
/// consumer, a background thread. Thread-safe; does nothing once the browser tab is closed or the
/// fragment is no longer drawn. For events that concern every open tab, use `refreshOn` with
/// `refreshFragments(topic)` instead.
struct FragmentRef
{
	private import streamlitd.session : AppSession;
	private AppSession sess;
	private string fid;

	/// Rerun the fragment now (without waiting for `runEvery`). Returns whether it was queued.
	bool refresh()
	{
		return sess !is null && sess.requestFragmentRefresh(fid);
	}

	/// Is the fragment still on an open page? (Its last full run drew it.)
	bool alive()
	{
		return sess !is null && !sess.isClosed() && sess.isFragmentKnown(fid);
	}

	/// The fragment's id (`"fk:<key>"` with a `key`).
	@property string id() const { return fid; }
}

/// Rerun every fragment drawn with `refreshOn: topic`, in every open browser tab, now, without
/// waiting for `runEvery`. Thread-safe: call it from API routes, background threads, file
/// watchers or app code. Returns the number of fragments queued.
size_t refreshFragments(string topic)
{
	import streamlitd.session : AppSession;
	import streamlitd.liveregistry : liveSessions;
	size_t n;
	foreach (o; liveSessions())
		n += (cast(AppSession) o).refreshTopic(topic);
	return n;
}

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
	/// Event-driven updates (streamlitd only): `refreshWhen` is asked each time a `runEvery` run
	/// is due, and `false` skips that run (nothing runs, nothing is sent) until the next period; it
	/// runs on the server's event loop, so keep it light (a version counter, a file's modification
	/// time). `refreshOn` subscribes the fragment to topics (comma-separated), which
	/// `refreshFragments(topic)` reruns at once in every open tab, from any thread. The returned
	/// `FragmentRef` reruns this fragment in this tab with `refresh()`.
	FragmentRef fragment(void delegate(St) body_, double runEvery = 0, string key = null,
		bool delegate() refreshWhen = null, string refreshOn = null)
	{
		import std.algorithm : map, filter;
		import std.array : array, split;
		import std.string : strip;
		auto topics = refreshOn.split(",").map!(t => t.strip).filter!(t => t.length > 0).array;
		auto blk = emitBlock("fragment", jo("runEvery", runEvery));
		auto fid = key.length ? "fk:" ~ key : "f:" ~ pathKey(blk.path);
		sess.registerFragment(fid, body_, blk.path.dup, formId, runEvery, refreshWhen, topics);
		blk.fragmentId = fid;
		body_(blk);
		return FragmentRef(sess, fid);
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
