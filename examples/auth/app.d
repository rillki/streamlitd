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

mixin StreamlitMain!app;
