/// `St` — the DeltaGenerator. Every element/widget call goes through a `St`
/// which knows which container (path) it writes into.
module streamlitd.delta;

import std.variant;
import std.conv : to;
import std.array : join;
import vibe.data.json;

import streamlitd.session;
import streamlitd.state;
import streamlitd.errors;
import streamlitd.util;
import streamlitd.secrets : Secrets;
static import streamlitd.secrets;
import streamlitd.theme : Theme, validateTheme, themeJson;

import std.traits : isNumeric, isSomeString, isAssociativeArray, isArray, isIntegral, isFloatingPoint;
import std.datetime : Date, TimeOfDay, Clock;
import std.algorithm : startsWith;
import std.format : format;
import std.math : isInfinity;
import std.file : read;
import streamlitd.elements : ProgressBar, Spinner, progressElement, TimelineItem;
import streamlitd.dataframe : DataFrame;
import streamlitd.widgets : limitChars, formatOptions, numJ, jNum, dateStr, strDate, timeStr, strTime, TreeNode, DateRange, collectTreeIds, treeJson, normalizeTree;
import streamlitd.dataelements : applyEditorState;
import streamlitd.charts : buildChartSpec;
import streamlitd.media : MediaManager, UploadedFile;
import streamlitd.mediaelements : uploadsToJson, uploadsFromJson;
import streamlitd.pages : Page, slugify;

import streamlitd.elements : Elements;
import streamlitd.widgets : Widgets;
import streamlitd.layout : LayoutElements;
import streamlitd.dataelements : DataElements;
import streamlitd.charts : Charts;
import streamlitd.mediaelements : MediaElements;
import streamlitd.pages : PageElements;
import streamlitd.fragments : FragmentElements, StatusContainer;
import streamlitd.components : ComponentElements, ComponentsApi, findComponent;
import streamlitd.extensions : CustomElements, isElementRegistered;
import streamlitd.useradmin : AccountElements;
import streamlitd.accounts : Accounts;
static import streamlitd.accounts;

/// Root containers.
enum RootContainer : int
{
	main = 0,
	sidebar = 1,
	bottom = 2,   /// chat input
	// 3: dialogs
	topbar = 4,   /// right side of the header bar (`st.topbar`, `userMenu`)
	footer = 5,   /// under the main content (`st.footer`)
	banner = 6,   /// strip above the main content (`st.banner`)
}

/// The DeltaGenerator: the object passed to the app function (`st`) and returned by
/// container calls (`st.sidebar`, `st.columns(2)[0]`, `st.expander("x")` ...).
final class St
{
	package AppSession sess;
	package int[] path;      /// container path, or element path for slots
	package bool slot;       /// true for `st.empty()` placeholders
	package string formId;   /// set inside `st.form`
	package string formClear; /// formId if the form clears on submit
	package string fragmentId; /// set inside `st.fragment` / `st.dialog`

	package this(AppSession sess, int[] path, bool slot = false, string formId = null)
	{
		this.sess = sess;
		this.path = path;
		this.slot = slot;
		this.formId = formId;
	}

	// ---------------------------------------------------------------- core

	/// The per-session state (`st.session_state`).
	@property SessionState session() { return sess.session; }

	/// `st.secrets` — values from `.streamlitd/secrets.toml` (never sent to the browser).
	@property Secrets secrets() { return streamlitd.secrets.secrets(); }

	/// `st.user`: the logged-in user (see `[auth]` configuration).
	@property UserInfo user() { return UserInfo(sess.user); }

	/// `st.login`: send the browser to the login page (or straight to `provider`).
	void login(string provider = null)
	{
		import std.uri : encodeComponent;
		if (!sess.authEnabled)
			throw new StreamlitAPIException("st.login() needs authentication to be configured: add an [auth] section " ~
				"with users or OIDC providers to .streamlitd/secrets.toml");
		sess.send(jo("type", "navigate", "url", "auth/login" ~ (provider.length ? "?provider=" ~ encodeComponent(provider) : "")));
		throw new StopException;
	}

	/// `st.logout`: clear the login cookie.
	void logout()
	{
		if (!sess.authEnabled)
			throw new StreamlitAPIException("st.logout() needs authentication to be configured ([auth] in secrets.toml)");
		sess.send(jo("type", "navigate", "url", "auth/logout"));
		throw new StopException;
	}

	/// The underlying session object.
	@property AppSession appSession() { return sess; }

	/// Allocate the path of the next element in this container.
	package int[] nextPath()
	{
		if (slot)
			return path.dup;
		auto k = pathKey(path);
		auto i = sess.cursors.get(k, 0);
		sess.cursors[k] = i + 1;
		return path ~ i;
	}

	/// Emit an element into this container; returns its path.
	package int[] emit(Json el)
	{
		sess.checkInterrupt();
		auto p = nextPath();
		sess.cursors.remove(pathKey(p)); // a re-emitted block starts with fresh children
		sess.sendDelta(p, el);
		return p;
	}

	/// Re-emit an element at a fixed path (used by updatable elements).
	package void emitAt(const int[] p, Json el)
	{
		sess.checkInterrupt();
		sess.sendDelta(p, el);
	}

	/// Emit a block (container) element and return a generator writing into it.
	package St emitBlock(string blockType, Json props = Json.emptyObject)
	{
		if (props.type != Json.Type.object)
			props = Json.emptyObject;
		props["kind"] = "block";
		props["block"] = blockType;
		if (fragmentId.length)
			props["fragment"] = fragmentId; // e.g. forms inside a fragment submit as fragment reruns
		auto p = emit(props);
		auto c = new St(sess, p, false, formId);
		c.formClear = formClear;
		c.fragmentId = fragmentId;
		return c;
	}

	/// Compute a widget id.
	package string widgetId(string kind, string key, string[] parts...)
	{
		if (key.length)
			return "k:" ~ key;
		return "w:" ~ kind ~ ":" ~ hashHex(kind ~ "\x01" ~ parts.join("\x01") ~ "\x01" ~ formId);
	}

	/// Shared widget implementation: resolves the current value from session/widget state,
	/// registers metadata for callbacks, emits the element and returns the value.
	package T widget(T)(string kind, string id, string key, T def,
		Json delegate(T) enc, T delegate(Json) dec,
		void delegate() onChange, Json props, bool trigger = false, Json delegate(T) lateProps = null)
	{
		sess.checkInterrupt();
		if (id in sess.seenIds)
			throw new DuplicateWidgetID("There are multiple `" ~ kind ~ "` widgets with the same id (`" ~ id ~
				"`). Pass a unique `key` argument to each of them.");
		sess.seenIds[id] = true;

		T value = def;
		if (trigger)
		{
			if (sess.triggerId == id)
			{
				try
					value = dec(sess.triggerValue);
				catch (Exception)
					value = def;
			}
		}
		else if (key.length && (key in sess.session.dirty) && sess.session.has(key))
		{
			try
				value = convertVariant!T(sess.session[key], key);
			catch (Exception)
				value = def;
		}
		else if (auto p = id in sess.widgetValues)
		{
			try
				value = dec(*p);
			catch (Exception)
				value = def;
		}
		else if (key.length && sess.session.has(key))
		{
			try
				value = convertVariant!T(sess.session[key], key);
			catch (Exception)
				value = def;
		}

		T renderValue = value;
		if (!trigger)
		{
			if (formId.length && formClear == formId && isClearingForm())
			{
				renderValue = def;
				sess.widgetValues[id] = enc(def);
			}
			else
				sess.widgetValues[id] = enc(value);
		}
		if (key.length)
			sess.session.setRaw(key, Variant(value));

		WidgetMeta m;
		m.key = key;
		m.decode = (Json j) => Variant(dec(j));
		m.onChange = onChange;
		m.trigger = trigger;
		sess.newWidgetMeta[id] = m;

		if (lateProps !is null)
			props = lateProps(value);
		if (props.type != Json.Type.object)
			props = Json.emptyObject;
		props["kind"] = kind;
		props["id"] = id;
		if (!trigger)
			props["value"] = enc(renderValue);
		if (formId.length)
			props["form"] = formId;
		if (fragmentId.length)
		{
			props["fragment"] = fragmentId;
			sess.fragmentWidget(fragmentId, id);
		}
		emit(props);
		return value;
	}

	private bool isClearingForm()
	{
		if (auto p = "clearingForm" in sess.internals)
			return p.get!string == formId;
		return false;
	}

	// ---------------------------------------------------------- control flow

	/// Stop the current run (`st.stop()`).
	void stop() { throw new StopException; }

	/// Rerun immediately (`st.rerun()`). `scope_: "fragment"` reruns only the current
	/// fragment when called during a fragment run; otherwise the whole app reruns.
	void rerun(string scope_ = "app")
	{
		if (scope_ == "fragment" && sess.runningFragment && sess.currentFragment.length)
			sess.markFragmentRerun(sess.currentFragment);
		else
			sess.markRerun();
		throw new RerunException;
	}

	/// Sleep without blocking other sessions (yields to the event loop).
	void sleep(double seconds)
	{
		import vibe.core.core : vsleep = sleep;
		import core.time : msecs;
		sess.checkInterrupt();
		try
			vsleep((cast(long)(seconds * 1000)).msecs);
		catch (Exception) {}
		sess.checkInterrupt();
	}

	/// Configure the page (`st.set_page_config`). `icon` is the browser-tab favicon: an emoji, an
	/// http(s)/data URL, or a local image file. `colorScheme` (alias `theme`) and `design`
	/// select the color scheme and design style (see `colorSchemeNames`, `designNames`);
	/// `allowThemeSwitch: false` hides the viewer's appearance menu.
	void setPageConfig(string title = null, string icon = null, Layout layout = Layout.centered,
		string initialSidebarState = "auto", string theme = null, bool allowThemeSwitch = true,
		string colorScheme = null, string design = null)
	{
		sess.send(jo("type", "page_config", "title", title, "icon", faviconSrc(icon),
			"layout", layout == Layout.wide ? "wide" : "centered", "sidebarState", initialSidebarState));
		if (theme !is null || colorScheme !is null || design !is null || !allowThemeSwitch)
		{
			Theme t = currentTheme();
			if (theme !is null)
				t.scheme = theme;
			if (colorScheme !is null)
				t.scheme = colorScheme;
			if (design !is null)
				t.design = design;
			// an earlier lock in this run (setTheme(t, allowThemeSwitch: false)) is kept
			setTheme(t, allowThemeSwitch && sess.appAllowSwitch);
		}
	}

	/// Change the color scheme, mode ("auto", "light", "dark") and/or design style. Parts left
	/// `null` keep their current value: `st.setTheme(design: "terminal")` only changes the design.
	void setTheme(string scheme = null, string mode = null, string design = null)
	{
		Theme t = currentTheme();
		if (scheme !is null)
			t.scheme = scheme;
		if (mode !is null)
			t.mode = mode;
		if (design !is null)
			t.design = design;
		setTheme(t, sess.appAllowSwitch); // keeps a lock set earlier in this run
	}

	/// Set a full theme: color scheme + mode + design style + Streamlit-style overrides
	/// (`primaryColor`, `font`, ...). `allowThemeSwitch: false` hides the viewer's appearance
	/// menu; the lock holds for the rest of the run (later partial `setTheme` calls keep it).
	void setTheme(Theme theme, bool allowThemeSwitch = true)
	{
		validateTheme(theme);
		sess.checkInterrupt();
		sess.appTheme = theme;
		sess.appThemeSet = true;
		sess.appAllowSwitch = allowThemeSwitch;
		auto m = themeJson(theme, allowThemeSwitch && sess.allowThemeSwitch);
		m["type"] = "set_theme";
		sess.send(m);
	}

	/// The theme last set by the app in this session (or the server default).
	Theme currentTheme()
	{
		return sess.appThemeSet ? sess.appTheme : sess.defaultTheme;
	}

	/// Show a toast notification (`st.toast`).
	void toast(string body_, string icon = null)
	{
		sess.checkInterrupt();
		sess.send(jo("type", "toast", "body", body_, "icon", icon));
	}

	/// Celebrate (`st.balloons`).
	void balloons()
	{
		sess.send(jo("type", "effect", "name", "balloons"));
	}

	/// Celebrate (`st.snow`).
	void snow()
	{
		sess.send(jo("type", "effect", "name", "snow"));
	}

	// ---------------------------------------------------------- query params

	/// Current URL query parameters (`st.query_params`).
	@property QueryParams queryParams() { return QueryParams(sess); }

	// ---------------------------------------------------------- mixins

	mixin Elements;
	mixin Widgets;
	mixin LayoutElements;
	mixin DataElements;
	mixin Charts;
	mixin MediaElements;
	mixin PageElements;
	mixin FragmentElements;
	mixin ComponentElements;
	mixin CustomElements;
	mixin AccountElements;
}

package UserInfo makeUserInfo(Json data) { return UserInfo(data); }

/// The logged-in user (`st.user`).
struct UserInfo
{
	private Json data;

	/// True when a user is logged in.
	@property bool isLoggedIn() const @trusted { return data.type == Json.Type.object; }
	/// Display name.
	@property string name() const @trusted { return isLoggedIn ? data["name"].opt!string(null) : null; }
	/// E-mail address (if the provider shares it).
	@property string email() const @trusted { return isLoggedIn ? data["email"].opt!string(null) : null; }
	/// Stable subject id from the provider (username for password logins).
	@property string sub() const @trusted { return isLoggedIn ? data["sub"].opt!string(null) : null; }
	/// "password" or the OIDC provider name.
	@property string provider() const @trusted { return isLoggedIn ? data["provider"].opt!string(null) : null; }
	/// The account name in the user store: the username for password users, `"<provider>:<sub>"`
	/// for OIDC users (what `st.accounts` methods take).
	@property string username() const @trusted
	{
		if (!isLoggedIn)
			return null;
		auto u = data["username"].opt!string(null);
		return u !is null ? u : provider == "password" ? sub : provider ~ ":" ~ sub;
	}
	/// Roles: from the user store, `roles` in `[auth.users.x]`, and "admin" for `[auth] admins`.
	@property string[] roles() const @trusted
	{
		string[] r;
		if (isLoggedIn && data["roles"].type == Json.Type.array)
			foreach (x; data["roles"])
				r ~= x.get!string;
		return r;
	}
	/// Has the user this role?
	bool hasRole(string role) const @trusted
	{
		import std.algorithm : canFind;
		return roles.canFind(role);
	}
	/// Has the user the "admin" role?
	@property bool isAdmin() const { return hasRole("admin"); }
	/// All stored claims.
	@property Json claims() const @trusted { return isLoggedIn ? data.clone : Json(null); }
}

/// Access to the browser's URL query string.
struct QueryParams
{
	private AppSession sess;

	/// Value of a parameter, or `def`.
	string get(string name, string def = null) { return sess.queryParams.get(name, def); }
	/// `st.queryParams["x"]`
	string opIndex(string name) { return sess.queryParams.get(name, null); }
	/// Set a parameter (updates the browser URL).
	void opIndexAssign(string value, string name)
	{
		sess.queryParams[name] = value;
		sync();
	}
	/// Remove a parameter.
	void remove(string name)
	{
		sess.queryParams.remove(name);
		sync();
	}
	/// Remove all parameters.
	void clear()
	{
		sess.queryParams = null;
		sync();
	}
	bool opBinaryRight(string op : "in")(string name) { return (name in sess.queryParams) !is null; }
	/// All parameters.
	string[string] toAA() { return sess.queryParams.dup; }

	private void sync()
	{
		sess.send(jo("type", "query_params", "params", sess.queryParams));
	}
}
