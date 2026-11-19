/// App-side account features mixed into `St`: `st.accounts`, `st.requireLogin`, `st.requireRole`
/// and the ready-made admin panel `st.userAdmin()`.
module streamlitd.useradmin;

/// Short date-time for tables ("2026-11-12 09:30", "never").
package string shortTime(long unix)
{
	import std.datetime : SysTime, unixTimeToStdTime, UTC;
	import std.format : format;
	if (unix <= 0)
		return "never";
	auto t = SysTime(unixTimeToStdTime(unix), UTC());
	return format("%04d-%02d-%02d %02d:%02d UTC", t.year, cast(int) t.month, t.day, t.hour, t.minute);
}

mixin template AccountElements()
{
	/// The account service (sign-up, users, roles, invites, reset links); see `streamlitd.accounts`.
	/// Passwords given to it are hashed automatically. Throws when `[auth]` is not configured.
	@property Accounts accounts()
	{
		auto a = streamlitd.accounts.accounts();
		if (a is null)
			throw new StreamlitAPIException("st.accounts needs authentication: add an [auth] section to .streamlitd/config.toml " ~
				"(e.g. registration = \"first_admin\")");
		return a;
	}

	/// Stop the run and send the browser to the login page when nobody is logged in.
	void requireLogin()
	{
		if (!user.isLoggedIn)
			login();
	}

	/// Show an error and stop the run unless the logged-in user has `role` (e.g. "admin");
	/// sends anonymous visitors to the login page.
	void requireRole(string role)
	{
		requireLogin();
		if (!user.hasRole(role))
		{
			error("You need the **" ~ role ~ "** role to see this page.", "🔒");
			stop();
		}
	}

	/// A ready-made user administration panel (streamlitd only), for admins: the users with
	/// their roles and status; approve, disable, reset links, log out everywhere, delete; adding
	/// users (passwords are hashed automatically) and one-time invites. Other users see an error.
	/// `key` keeps its widgets apart when there are several panels.
	void userAdmin(string key = "user-admin")
	{
		import std.algorithm : canFind, sort, uniq, map, filter;
		import std.array : array, join;
		import streamlitd.accounts : AccountError, Registration, registrationName, StoredUser;
		import streamlitd.useradmin : shortTime;
		import streamlitd.text : escapeMarkdown;
		auto acc = accounts;
		// usernames come from sign-up forms and SSO providers: shown as text, never as Markdown
		auto md = (string s) => escapeMarkdown(s);
		if (!user.isAdmin)
		{
			error("Only administrators can manage users.", "🔒");
			return;
		}
		auto me = user.username;
		auto k = (string s) => key ~ ":" ~ s;
		auto done = (string msg) { session[k("notice")] = msg; rerun(); };
		if (session.has(k("notice")))
		{
			auto n = session.get!string(k("notice"), null);
			session.remove(k("notice"));
			if (n.length)
				toast(n, "✅");
		}

		auto users = acc.users;
		string[] knownRoles = ["admin"] ~ acc.settings.defaultRoles;
		foreach (u; users)
			knownRoles ~= u.roles;
		knownRoles = knownRoles.sort.uniq.array;

		auto tabs = tabs(["Users", "Add user", "Invites"]);

		// ------------------------------------------------ users
		with (tabs[0])
		{
			caption("Sign-up: **" ~ registrationName(acc.settings.registration) ~ "**. " ~ users.length.to!string ~ " account(s)" ~
				(acc.configUsers.length ? "; " ~ acc.configUsers.length.to!string ~ " more in secrets.toml (read-only)" : "") ~ ".");
			if (users.length)
			{
				Json[][] rows;
				foreach (u; users)
					rows ~= [Json(u.username), Json(u.name), Json(u.email), Json(u.roles.join(", ")), Json(u.status),
						Json(u.provider.length ? u.provider : "password"), Json(shortTime(u.created)), Json(shortTime(u.lastLogin))];
				dataframe(DataFrame.fromRows(["Username", "Name", "Email", "Roles", "Status", "Sign-in", "Created", "Last login"], rows),
					0, true);
				auto names = users.map!(u => u.username).array;
				auto sel = selectbox("Manage user", names, -1, k("user"), null, null, false, "Choose a user");
				auto up = sel.length ? acc.user(sel) : null;
				if (up !is null)
				{
					auto u = *up;
					immutable self = u.username == me;
					try
					{
						auto roles = tagsInput("Roles", u.roles, knownRoles, 0, k("roles:" ~ u.username), "Type a role and press Enter");
						auto cols = columns(3);
						if (cols[0].button("Save roles", k("save-roles"), null, null, roles == u.roles, "primary"))
						{
							acc.setRoles(u.username, roles);
							done("Roles of " ~ md(u.username) ~ " saved");
						}
						if (u.pending && cols[1].button("Approve", k("approve"), null, null, false, "primary"))
						{
							acc.approve(u.username);
							done(md(u.username) ~ " can sign in now");
						}
						if (!u.pending && cols[1].button(u.disabled ? "Enable" : "Disable", k("disable"), self ? "You cannot disable yourself" : null,
							null, self))
						{
							acc.setDisabled(u.username, !u.disabled);
							done(md(u.username) ~ (u.disabled ? " enabled" : " disabled; their logins ended"));
						}
						if (cols[2].button("Log out everywhere", k("logout"), "End this user's logins on every device"))
						{
							acc.logoutEverywhere(u.username);
							done("Logins of " ~ md(u.username) ~ " ended");
						}
						if (!u.provider.length)
						{
							if (button("Create a password reset link", k("reset")))
								session[k("link:" ~ u.username)] = acc.createResetLink(u.username);
							auto link = session.get!string(k("link:" ~ u.username), null);
							if (link.length)
							{
								info("Send this link to **" ~ md(u.username) ~ "**. It works once, for 24 hours, and lets them set a new password.");
								code(link, "text");
								copyButton(link, "Copy link", "📋", null, true);
							}
						}
						else
							caption("Signs in with " ~ u.provider ~ "; the password is managed there.");
						auto sure = checkbox("Yes, delete " ~ u.username, false, k("sure"), self ? "You cannot delete yourself" : null, null, self);
						if (button("Delete user", k("delete"), null, null, !sure || self))
						{
							acc.deleteUser(u.username);
							session.remove(k("user"));
							done(md(u.username) ~ " deleted");
						}
					}
					catch (AccountError e)
						error(md(e.msg)); // messages quote what was typed
				}
			}
			else
				info("No accounts in the user store yet.");
		}

		// ------------------------------------------------ add user
		with (tabs[1])
		{
			auto f = form(k("add"), true);
			auto uname = f.textInput("Username", "", 64, k("add-username"));
			auto name = f.textInput("Full name", "", 0, k("add-name"));
			auto email = f.textInput("Email", "", 0, k("add-email"));
			auto pw = f.textInput("Password", "", 0, k("add-password"), "password", "At least " ~
				acc.settings.passwordMinLength.to!string ~ " characters; it is hashed before it is stored");
			auto roles = f.tagsInput("Roles", null, knownRoles, 0, k("add-roles"));
			if (f.formSubmitButton("Create user", null, null, "primary"))
			{
				try
				{
					auto u = acc.createUser(uname, pw, name, email, roles);
					success("Created **" ~ md(u.username) ~ "**. They can sign in now.");
				}
				catch (AccountError e)
					error(md(e.msg)); // messages quote what was typed
			}
		}

		// ------------------------------------------------ invites
		with (tabs[2])
		{
			if (acc.settings.registration != Registration.invite)
				caption("Invites are used when `[auth] registration = \"invite\"` (now: **" ~
					registrationName(acc.settings.registration) ~ "**).");
			auto cols = columns(2);
			auto roles = cols[0].tagsInput("Roles of the new account", acc.settings.defaultRoles, knownRoles, 0, k("inv-roles"));
			auto days = cols[1].numberInput("Valid for (days)", 7, 1, 90, 1, k("inv-days"));
			if (button("Create invite", k("inv-create"), null, null, false, "primary"))
				session[k("inv-link")] = acc.inviteLink(acc.createInvite(roles, cast(uint) days, me));
			auto link = session.get!string(k("inv-link"), null);
			if (link.length)
			{
				info("Send this sign-up link to the new user. It works once and expires after the chosen number of days.");
				code(link, "text");
				copyButton(link, "Copy invite link", "📋", null, true);
			}
			auto invs = acc.invites;
			if (invs.length)
			{
				Json[][] rows;
				foreach (i; invs)
					rows ~= [Json(i.id), Json(i.roles.join(", ")), Json(i.createdBy), Json(shortTime(i.created)), Json(shortTime(i.expires))];
				dataframe(DataFrame.fromRows(["Id", "Roles", "Created by", "Created", "Expires"], rows), 0, true);
				auto which = selectbox("Revoke invite", invs.map!(i => i.id).array, -1, k("inv-sel"), null, null, false, "Choose an invite");
				if (button("Revoke", k("inv-revoke"), null, null, which is null))
				{
					acc.revokeInvite(which);
					session.remove(k("inv-sel"));
					done("Invite revoked");
				}
			}
		}
	}
}
