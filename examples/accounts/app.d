/// Accounts: sign-up with automatic password hashing, roles, the admin panel and the account page.
/// Start it and open the app: the first account you create is the administrator.
import streamlitd;
import std.array : join;

void home(St st)
{
	auto u = st.user;
	st.title("👋 Welcome, " ~ escapeMarkdown(u.name));
	st.write("You are signed in as **" ~ escapeMarkdown(u.username) ~ "**. Roles: "
		~ (u.roles.length ? "**" ~ escapeMarkdown(u.roles.join(", ")) ~ "**" : "none") ~ ".");
	if (u.isAdmin)
		st.info("You are an administrator: add users, give roles and send invites on the **Admin** page.");
	st.caption("Change your name, email or password with **Account settings** in the user menu (top right).");
}

void reports(St st)
{
	st.requireRole("editor"); // an error and stop for everybody else
	st.title("📊 Reports");
	st.write("Only users with the **editor** role see this page.");
}

void admin(St st)
{
	st.title("🛡️ Users");
	st.userAdmin();
}

void app(St st)
{
	st.setPageConfig(title: "Accounts demo");
	Page[] pages = [Page(&home, "Home", "🏠"), Page(&reports, "Reports", "📊")];
	if (st.user.isAdmin)
		pages ~= Page(&admin, "Admin", "🛡️");
	auto page = st.navigation(pages, position: "top");
	if (st.userMenu(["Help"]) == "Help")
		st.toast("Ask an administrator for an invite to add a colleague.");
	page.run(st);
}

/// A JSON endpoint for admins only (403 for other users, 401 without a login).
void routes(URLRouter r)
{
	r.get("/api/users", (HTTPServerRequest req, HTTPServerResponse res) {
		requireRole(req, res, "admin");
		string[] names;
		foreach (u; accounts().users)
			names ~= u.username;
		res.writeJsonBody(["users": names]);
	});
}

mixin StreamlitMain!(app, routes);
