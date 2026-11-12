/// Login: password users from secrets.toml and an OIDC provider; the whole app requires a login.
/// Alice is an admin (`roles` in secrets.toml) and sees the user administration panel.
import streamlitd;

void app(St st)
{
	st.title("Members area");
	auto u = st.user;
	st.write("Hello **" ~ u.name ~ "**" ~ (u.email.length ? " (" ~ u.email ~ ")" : "") ~ ", signed in via " ~ u.provider ~ ".");
	if (st.button("Log out"))
		st.logout();
	// the user menu in the header bar: picture or initials, the app's items and "Log out"
	auto picked = st.userMenu(["Profile", "-", "Help"]);
	if (picked.length)
		st.info("You picked **" ~ picked ~ "** in the user menu.");
	// alice has roles = ["admin"] in secrets.toml: she manages the users who signed in with SSO
	if (u.isAdmin)
	{
		st.subheader("Users");
		st.userAdmin();
	}
}

/// A JSON endpoint behind the same login ([auth] required = true answers 401 to anonymous calls).
void routes(URLRouter r)
{
	r.get("/api/whoami", (HTTPServerRequest req, HTTPServerResponse res) {
		auto u = requireUser(req, res);
		res.writeJsonBody(["name": u.name, "email": u.email, "provider": u.provider]);
	});
}

mixin StreamlitMain!(app, routes);
