/// Login: password users and an OIDC provider; the whole app requires a login.
import streamlitd;

void app(St st)
{
	st.title("Members area");
	auto u = st.user;
	st.write("Hello **" ~ u.name ~ "**" ~ (u.email.length ? " (" ~ u.email ~ ")" : "") ~ ", signed in via " ~ u.provider ~ ".");
	if (st.button("Log out"))
		st.logout();
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
