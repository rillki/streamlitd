/// One browser session: holds widget values and session state, and reruns the app.
module streamlitd.session;

import std.variant;
import core.time : MonoTime, msecs, Duration;
import core.sync.mutex : Mutex;
import vibe.data.json;

import streamlitd.delta;
import streamlitd.errors;
import streamlitd.media;
import streamlitd.state;
import streamlitd.util;
import streamlitd.theme : Theme, presetsJson, designsJson, themeJson;

/// The app entry point: called on every rerun.
alias AppFn = void delegate(St st);

/// Sends messages to the browser.
interface Transport
{
	void send(Json msg);
}

/// Transport that records messages (used for tests / headless runs).
final class RecordingTransport : Transport
{
	Json[] messages;
	void send(Json msg) { messages ~= msg; }

	/// All delta elements sent, in order.
	Json[] deltas()
	{
		Json[] r;
		foreach (m; messages)
			if (m["type"].get!string == "delta")
				r ~= m;
		return r;
	}

	/// Messages of a type.
	Json[] ofType(string type)
	{
		Json[] r;
		foreach (m; messages)
			if (m["type"].get!string == type)
				r ~= m;
		return r;
	}

	void clear() { messages = null; }
}

/// Registered information about a widget from the previous run.
struct WidgetMeta
{
	string key;
	Variant delegate(Json) decode;
	void delegate() onChange;
	bool trigger;
	string clearsForm; /// for form submit buttons of `clearOnSubmit` forms
}

/// A registered `st.fragment` (or `st.dialog`): can be rerun on its own.
final class FragmentInfo
{
	string id;
	void delegate(St) fn;
	int[] path;          /// container path of the fragment block
	string formId;
	double runEvery = 0; /// seconds; 0 = only on interaction
	bool[string] widgetIds;
	MonoTime lastRun;
}

/// Outcome of a script run.
enum RunStatus { ok, error, stopped, rerun }

/// Page layout passed to `st.setPageConfig`.
enum Layout { centered, wide }

/// Page configuration.
struct PageConfig
{
	string title;
	string icon;
	Layout layout = Layout.centered;
	string sidebarState = "auto"; /// "auto", "expanded", "collapsed"
}

/// A browser session.
final class AppSession
{
	string id;
	AppFn appFn;
	Transport transport;
	SessionState session;

	// widget registry
	Json[string] widgetValues;
	WidgetMeta[string] widgetMeta;
	package WidgetMeta[string] newWidgetMeta;

	// pending client events
	package Json[string] pendingUpdates;
	package string pendingTrigger;
	package Json pendingTriggerValue;
	package string[string] pendingQuery;
	package bool pendingQuerySet;
	package string pendingPage;
	package bool pendingPageSet;
	/// Guards the pending-event fields and flags shared between the receiving task
	/// and the (possibly worker-thread) script run.
	package Mutex lock;
	bool rerunRequested;     /// full app rerun pending
	/// Fragments waiting for a fragment-only rerun, in request order.
	package string[] pendingFragments;
	/// Fragment that owns the pending trigger (button click), if any.
	package string pendingTriggerFragment;
	bool closed;
	bool running;
	package bool runningFragment;
	package string currentFragment;

	/// Fragments registered by the last full run (id -> info).
	package FragmentInfo[string] fragments;
	package FragmentInfo[string] newFragments;
	/// Ids of registered fragments (guarded by `lock`; readable from the receiving task).
	private bool[string] knownFragments;
	/// Called (from the receiving task) whenever a rerun was requested.
	void delegate() onRerunRequested;
	/// Lets the event loop process incoming messages during long runs (set by the server).
	void delegate() yielder;
	private MonoTime lastYield;

	// per-run context
	package string triggerId;
	package Json triggerValue;
	package bool[string] seenIds;
	package int[string] cursors;
	/// Media in use: media id -> owners ("" = main script, otherwise a fragment id).
	package bool[string][string] mediaRefs;
	package int runId;
	package bool pageConfigSent;
	package bool chatInputUsed;

	// browser location
	string[string] queryParams;
	string pagePath;
	package string[] navPagePaths;
	/// Breadcrumb trail of the current page from `st.navigation` ([{label, urlPath}]), for `st.breadcrumbs()`.
	package Json navCrumbs;

	/// The logged-in user (`st.user`), or `Json(null)`. Set from the auth cookie on connect.
	Json user;
	/// True when `[auth]` is configured (login routes exist).
	bool authEnabled;

	/// Map tiles for `st.map` (from `[map]` config).
	string mapTileUrl = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
	string mapAttribution = "&copy; OpenStreetMap contributors";

	/// App-wide default theme (from server options / CLI).
	Theme defaultTheme;
	/// Theme last set with `st.setTheme` in this session.
	package Theme appTheme;
	package bool appThemeSet;
	/// Viewer appearance menu allowed in the current run (reset at the start of each full run).
	package bool appAllowSwitch = true;
	/// Whether viewers may change style/mode from the settings menu.
	bool allowThemeSwitch = true;

	/// Per-session scratch values for library internals.
	package Variant[string] internals;

	this(AppFn fn, Transport transport)
	{
		this.id = randomId();
		this.appFn = fn;
		this.transport = transport;
		this.session = new SessionState;
		this.lock = new Mutex;
	}

	/// Mark the session closed (aborts a running script at its next `st.*` call).
	void close()
	{
		synchronized (lock)
			closed = true;
	}

	/// Thread-safe read of the closed flag.
	bool isClosed()
	{
		synchronized (lock)
			return closed;
	}

	/// Thread-safe read of the rerun flag (full or fragment rerun pending).
	bool isRerunRequested()
	{
		synchronized (lock)
			return rerunRequested || pendingFragments.length > 0;
	}

	/// Request a rerun of only the given fragment after the current run (`st.rerun(scope: "fragment")`).
	void markFragmentRerun(string fragmentId)
	{
		synchronized (lock)
		{
			if (!rerunRequested)
			{
				queueFragment(fragmentId);
			}
		}
	}

	/// Request another full run after the current one (used by `st.rerun()`).
	void markRerun()
	{
		synchronized (lock)
			rerunRequested = true;
	}

	/// Send a message to the browser (no-op once closed).
	void send(Json msg)
	{
		if (closed || transport is null)
			return;
		transport.send(msg);
	}

	/// Send an element to be rendered at `path`.
	void sendDelta(const int[] path, Json el)
	{
		send(jo("type", "delta", "path", path.dup, "el", el, "run", runId));
	}

	/// Message sent once when the connection is opened.
	Json newSessionMessage()
	{
		return jo("type", "new_session", "sessionId", id, "themes", presetsJson(), "designs", designsJson(),
			"theme", themeJson(defaultTheme, allowThemeSwitch));
	}

	/// Process a message from the browser.
	void handleClientMessage(Json msg)
	{
		auto type = msg["type"].opt!string("");
		switch (type)
		{
			case "rerun":
				Json[string] updates;
				if (msg["updates"].type == Json.Type.object)
					foreach (string k, v; msg["updates"])
						updates[k] = v;
				string trigger = msg["trigger"].opt!string(null);
				Json tval = msg["triggerValue"];
				string fragment = msg["fragment"].opt!string(null);
				synchronized (lock)
				{
					if (msg["query"].type == Json.Type.object)
					{
						string[string] q;
						foreach (string k, v; msg["query"])
							q[k] = v.type == Json.Type.string ? v.get!string : v.toString;
						pendingQuery = q;
						pendingQuerySet = true;
					}
					if (msg["page"].type == Json.Type.string)
					{
						pendingPage = msg["page"].get!string;
						pendingPageSet = true;
					}
				}
				requestRerun(updates, trigger, tval, fragment);
				break;
			default:
				break;
		}
	}

	/// Queue widget updates and ask for a rerun.
	/// With `fragment` set, only that fragment reruns (unless a full run is pending or running,
	/// or a different fragment is already queued; then the whole app reruns).
	void requestRerun(Json[string] updates = null, string trigger = null, Json triggerVal = Json.undefined,
		string fragment = null)
	{
		synchronized (lock)
		{
			foreach (k, v; updates)
				pendingUpdates[k] = v;
			if (trigger !is null)
			{
				pendingTrigger = trigger;
				pendingTriggerValue = triggerVal;
				pendingTriggerFragment = fragment;
			}
			// Unknown fragments rerun the whole app; requests for different fragments are queued
			// (they never escalate to a full rerun, so e.g. an open dialog stays open).
			if (fragment is null || fragment !in knownFragments)
				rerunRequested = true;
			else
				queueFragment(fragment);
		}
		if (onRerunRequested !is null)
			onRerunRequested();
	}

	private void queueFragment(string fid)
	{
		import std.algorithm : canFind;
		if (!pendingFragments.canFind(fid))
			pendingFragments ~= fid;
	}

	/// Called by every `st.*` call: aborts the run if a newer run is pending.
	void checkInterrupt()
	{
		if (yielder !is null && running)
		{
			auto now = MonoTime.currTime;
			if (now - lastYield > 30.msecs)
			{
				lastYield = now;
				yielder();
			}
		}
		bool abort;
		synchronized (lock)
		{
			import std.algorithm : canFind;
			// a fragment run is only interrupted by a full rerun or a new request for the same fragment
			abort = closed || (running && (rerunRequested || (runningFragment && pendingFragments.canFind(currentFragment))));
		}
		if (abort)
			throw new RerunException;
	}

	/// Run the app once (applying pending updates first). Synchronous.
	RunStatus runOnce()
	{
		return execute(null);
	}

	/// Run only a registered fragment (applying pending updates first).
	RunStatus runFragment(string fragmentId)
	{
		return execute(fragmentId);
	}

	/// Run whatever is pending: a full rerun takes precedence over a fragment rerun.
	RunStatus runPending()
	{
		string frag;
		bool full;
		synchronized (lock)
		{
			full = rerunRequested;
			// run the fragment owning a pending click first, so the click is not consumed elsewhere
			import std.algorithm : canFind;
			if (pendingTrigger !is null && pendingTriggerFragment.length && pendingFragments.canFind(pendingTriggerFragment))
				frag = pendingTriggerFragment;
			else if (pendingFragments.length)
				frag = pendingFragments[0];
		}
		if (!full && frag.length && frag in fragments)
			return runFragment(frag);
		return runOnce();
	}

	private RunStatus execute(string fragmentId)
	{
		FragmentInfo frag;
		if (fragmentId !is null)
		{
			frag = fragments.get(fragmentId, null);
			if (frag is null)
				fragmentId = null; // unknown (stale) fragment: full rerun
		}
		immutable isFragment = fragmentId !is null;

		running = true;
		runningFragment = isFragment;
		currentFragment = fragmentId;
		scope (exit)
		{
			running = false;
			runningFragment = false;
			currentFragment = null;
		}
		runId++;

		Json[string] updates;
		synchronized (lock)
		{
			if (!isFragment)
			{
				rerunRequested = false;
				pendingFragments = null; // a full run covers every fragment
			}
			else
			{
				import std.algorithm : remove;
				pendingFragments = pendingFragments.remove!(f => f == fragmentId);
			}
			updates = pendingUpdates;
			pendingUpdates = null;
			// a click belongs to the run of its own fragment (or to any full run)
			if (!isFragment || pendingTriggerFragment == fragmentId)
			{
				triggerId = pendingTrigger;
				triggerValue = pendingTriggerValue;
				pendingTrigger = null;
				pendingTriggerValue = Json.undefined;
				pendingTriggerFragment = null;
			}
			else
			{
				triggerId = null;
				triggerValue = Json.undefined;
			}
			if (pendingQuerySet)
				queryParams = pendingQuery;
			if (pendingPageSet)
				pagePath = pendingPage;
			pendingQuerySet = pendingPageSet = false;
		}

		internals.remove("clearingForm");
		if (triggerId !is null)
			if (auto m = triggerId in widgetMeta)
				if (m.clearsForm.length)
					internals["clearingForm"] = Variant(m.clearsForm);

		seenIds = null;
		cursors = null;
		newWidgetMeta = null;
		if (!isFragment)
		{
			mediaRefs = null;
			newFragments = null;
			navCrumbs = Json.undefined;
			appAllowSwitch = true;
			pageConfigSent = false;
			chatInputUsed = false;
		}

		St root;
		if (isFragment)
		{
			root = new St(this, frag.path.dup, false, frag.formId);
			root.fragmentId = fragmentId;
			frag.lastRun = MonoTime.currTime;
			foreach (mid, ref owners; mediaRefs)
				owners.remove(fragmentId);
			send(jo("type", "script_started", "run", runId, "fragment", fragmentId, "path", frag.path.dup));
		}
		else
		{
			root = new St(this, [0]);
			send(jo("type", "script_started", "run", runId));
		}

		// apply widget updates
		string[] changed;
		foreach (wid, v; updates)
		{
			auto old = wid in widgetValues;
			if (old is null || *old != v)
				changed ~= wid;
			widgetValues[wid] = v;
			if (auto m = wid in widgetMeta)
				if (m.key.length && m.decode !is null)
				{
					try
						session.setRaw(m.key, m.decode(v));
					catch (Exception) {}
				}
		}

		RunStatus status = RunStatus.ok;
		try
		{
			// callbacks run before the script, like in Streamlit
			running = false; // callbacks may not be interrupted
			foreach (wid; changed)
				if (auto m = wid in widgetMeta)
					if (m.onChange !is null && !m.trigger)
						m.onChange();
			if (triggerId !is null)
				if (auto m = triggerId in widgetMeta)
					if (m.onChange !is null)
						m.onChange();
			running = true;

			if (isFragment)
				frag.fn(root);
			else
				appFn(root);
		}
		catch (RerunException)
			status = RunStatus.rerun;
		catch (StopException)
			status = RunStatus.stopped;
		catch (Throwable e)
		{
			// Errors too (e.g. RangeError from an out-of-bounds index): show them like
			// Streamlit does instead of leaving the page stuck in "Running...".
			status = RunStatus.error;
			running = false;
			try
				root.exception(e);
			catch (Throwable) {}
		}
		running = false;

		if (isFragment)
		{
			// only this fragment's widgets are touched
			foreach (k, v; newWidgetMeta)
				widgetMeta[k] = v;
			if (status != RunStatus.rerun)
			{
				foreach (k, _; frag.widgetIds)
					if (k !in seenIds)
					{
						widgetValues.remove(k);
						widgetMeta.remove(k);
					}
				frag.widgetIds = seenIds.dup;
				releaseUnusedMedia();
			}
		}
		else if (status == RunStatus.rerun)
		{
			foreach (k, v; newWidgetMeta)
				widgetMeta[k] = v;
			foreach (k, v; newFragments)
				fragments[k] = v;
		}
		else
		{
			widgetMeta = newWidgetMeta;
			fragments = newFragments;
			string[] gone;
			foreach (k, _; widgetValues)
				if (k !in seenIds)
					gone ~= k;
			foreach (k; gone)
				widgetValues.remove(k);
			releaseUnusedMedia();
		}

		synchronized (lock)
		{
			knownFragments = null;
			foreach (k, _; fragments)
				knownFragments[k] = true;
		}

		if (isFragment)
			send(jo("type", "script_finished", "run", runId, "status", statusName(status), "fragment", fragmentId));
		else
			send(jo("type", "script_finished", "run", runId, "status", statusName(status)));
		return status;
	}

	/// Record that media `mid` is used by `owner` ("" = main script, else a fragment id).
	package void useMedia(string mid, string owner)
	{
		mediaRefs[mid][owner] = true;
	}

	/// Release media that no part of the page references any more.
	private void releaseUnusedMedia()
	{
		bool[string] keep;
		string[] dead;
		foreach (mid, owners; mediaRefs)
		{
			if (owners.length)
				keep[mid] = true;
			else
				dead ~= mid;
		}
		foreach (mid; dead)
			mediaRefs.remove(mid);
		MediaManager.releaseExcept(id, keep);
	}

	/// Register a fragment created during the current run.
	package FragmentInfo registerFragment(string fid, void delegate(St) fn, int[] path, string formId, double runEvery)
	{
		auto info = new FragmentInfo;
		info.id = fid;
		info.fn = fn;
		info.path = path;
		info.formId = formId;
		info.runEvery = runEvery;
		info.lastRun = MonoTime.currTime;
		if (auto old = fid in fragments)
			info.lastRun = old.lastRun;
		if (runningFragment)
			fragments[fid] = info;
		else
			newFragments[fid] = info;
		return info;
	}

	/// Note that widget `wid` belongs to fragment `fid`.
	package void fragmentWidget(string fid, string wid)
	{
		if (auto f = fid in (runningFragment ? fragments : newFragments))
			(*f).widgetIds[wid] = true;
		else if (auto f2 = fid in fragments)
			(*f2).widgetIds[wid] = true;
	}

	/// Time until the next `runEvery` fragment is due (Duration.max if none); sets `due` to its id when due now.
	Duration nextFragmentDue(out string due)
	{
		auto now = MonoTime.currTime;
		Duration best = Duration.max;
		foreach (fid, f; fragments)
		{
			if (f.runEvery <= 0)
				continue;
			auto period = (cast(long)(f.runEvery * 1000)).msecs;
			auto left = (f.lastRun + period) - now;
			if (left <= Duration.zero)
			{
				due = fid;
				return Duration.zero;
			}
			if (left < best)
				best = left;
		}
		return best;
	}

	/// Run while reruns are pending (used by headless drivers / tests).
	RunStatus runUntilIdle()
	{
		RunStatus s;
		do
			s = runPending();
		while (isRerunRequested() && !isClosed());
		return s;
	}

	static string statusName(RunStatus s)
	{
		final switch (s)
		{
			case RunStatus.ok: return "ok";
			case RunStatus.error: return "error";
			case RunStatus.stopped: return "stopped";
			case RunStatus.rerun: return "rerun";
		}
	}
}
