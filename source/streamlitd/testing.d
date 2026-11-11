/// Headless app testing (the counterpart of Streamlit's `AppTest`).
///
/// ---
/// auto at = new AppTest(&app).run();
/// at.setValue("text_input", "Name", Json("Ann")).run();
/// assert(at.markdowns.canFind("Hello Ann"));
/// ---
module streamlitd.testing;

import std.algorithm;
import std.array;
import std.conv : to;
import std.functional : toDelegate;
import vibe.data.json;

import streamlitd.delta : St;
import streamlitd.session;
import streamlitd.errors;
import streamlitd.util;

/// Runs an app without a browser and inspects its output.
final class AppTest
{
	AppSession sess;
	RecordingTransport transport;
	RunStatus lastStatus;
	private Json[] lastElements;
	// persistent element tree (like the browser): full runs replace it, fragment runs only their subtree
	private Json[string] treeEls;
	private int[][string] treePaths;

	this(AppFn fn)
	{
		transport = new RecordingTransport;
		sess = new AppSession(fn, transport);
	}

	this(void function(St) fn) { this(toDelegate(fn)); }

	/// Run the app (applying pending updates) until no rerun is pending.
	AppTest run()
	{
		transport.clear();
		if (!sess.isRerunRequested())
			sess.requestRerun();
		lastStatus = sess.runUntilIdle();
		collect();
		return this;
	}

	private void dropUnder(string k, bool inclusive)
	{
		foreach (kk; treeEls.keys)
			if ((inclusive && kk == k) || (kk.length > k.length && kk.startsWith(k ~ ".")))
			{
				treeEls.remove(kk);
				treePaths.remove(kk);
			}
	}

	private void collect()
	{
		foreach (m; transport.messages)
		{
			auto type = m["type"].get!string;
			if (type == "script_started")
			{
				if (m["fragment"].type == Json.Type.string)
				{
					int[] p;
					foreach (e; m["path"])
						p ~= e.get!int;
					dropUnder(pathKey(p), false);
				}
				else
				{
					treeEls = null;
					treePaths = null;
				}
			}
			else if (type == "delta")
			{
				int[] p;
				foreach (e; m["path"])
					p ~= e.get!int;
				auto k = pathKey(p);
				// a re-emitted block clears everything below it (unless it is just an update)
				if (!m["el"]["update"].opt!bool(false))
					dropUnder(k, false);
				treeEls[k] = m["el"];
				treePaths[k] = p;
			}
		}
		auto keys = treePaths.keys;
		keys.sort!((a, b) => treePaths[a] < treePaths[b]);
		lastElements = keys.map!(k => treeEls[k]).filter!(e => e["kind"].get!string != "empty").array;
	}

	/// All elements of the last run, in document order (optionally of one kind).
	Json[] elements(string kind = null)
	{
		if (kind is null)
			return lastElements;
		return lastElements.filter!(e => e["kind"].get!string == kind).array;
	}

	/// Custom elements and widgets of the last run (`st.customElement`, `st.customWidget`) named `name`.
	Json[] customElements(string name)
	{
		return elements("custom").filter!(e => e["element"].opt!string(null) == name).array;
	}

	/// Find a widget by kind and label.
	Json widget(string kind, string label)
	{
		foreach (e; lastElements)
			if (e["kind"].get!string == kind && e["label"].opt!string(null) == label)
				return e;
		throw new Exception("no " ~ kind ~ " widget labelled '" ~ label ~ "'");
	}

	/// Find a widget id by kind and label.
	string widgetId(string kind, string label) { return widget(kind, label)["id"].get!string; }

	/// Queue a new widget value (call `run()` afterwards).
	AppTest setValue(string kind, string label, Json value)
	{
		auto w = widget(kind, label);
		sess.requestRerun([w["id"].get!string: value], null, Json.undefined, w["fragment"].opt!string(null));
		return this;
	}

	/// Queue a value by widget id.
	AppTest setValueById(string id, Json value)
	{
		sess.requestRerun([id: value]);
		return this;
	}

	/// Click a button (call `run()` afterwards).
	AppTest click(string label, string kind = "button")
	{
		auto w = widget(kind, label);
		sess.requestRerun(null, w["id"].get!string, Json(true), w["fragment"].opt!string(null));
		return this;
	}

	/// Number of script runs (full and fragment) started so far.
	int runCount() { return sess.runId; }

	/// Submit a chat message (call `run()` afterwards).
	AppTest chat(string message)
	{
		auto e = elements("chat_input");
		if (e.length == 0)
			throw new Exception("no chat_input");
		sess.requestRerun(null, e[0]["id"].get!string, Json(message));
		return this;
	}

	/// Submit a form: sends the given updates together with the submit button trigger.
	AppTest submitForm(string buttonLabel, Json[string] updates = null)
	{
		sess.requestRerun(updates, widgetId("form_submit_button", buttonLabel), Json(true));
		return this;
	}

	/// Body texts of an element kind (markdown, heading, alert, text, code ...).
	string[] texts(string kind)
	{
		return elements(kind).map!(e => e["body"].opt!string(null)).array;
	}

	string[] markdowns() { return texts("markdown"); }
	string[] headings() { return texts("heading"); }
	string[] alerts() { return texts("alert"); }

	/// Exceptions shown on the page.
	Json[] exceptions() { return elements("exception"); }

	/// Messages of a given type sent in the last run (e.g. "toast").
	Json[] messages(string type) { return transport.ofType(type); }

	/// Session state.
	auto session() { return sess.session; }
}
