/// Admin: user administration, for the admin role only.
module helpdesk.pages.admin;

import streamlitd;

void admin(St st)
{
	st.requireRole("admin"); // an error and stop for everybody else
	st.title("Users");
	st.caption("Demo users come from secrets.toml (read-only); people who sign in through SSO or are added here appear below.");
	st.userAdmin();
}
