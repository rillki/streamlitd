# Authentication

streamlitd supports two kinds of login, configured like Streamlit 1.42+ in the `[auth]`
section of `secrets.toml` (or `config.toml`):

- **Password users**: a built-in login form with PBKDF2-hashed passwords.
- **OpenID Connect (OIDC)** single sign-on: Google, Microsoft Entra ID, Keycloak, Okta, Auth0, …

![login page](images/login.png)

## Quick setup: password users

1. Create a hash for each password:

   ```sh
   echo 'correct horse battery staple' | ./myapp --hash-password
   # pbkdf2_sha256$200000$xgHJl/rAQQ6zRJuwW4AR1w==$CMWkvQX5nykREqzNBppOqEhGIYS2WRxWaBhbDxjpDsM=
   ```

2. Add the users to `.streamlitd/secrets.toml`:

   ```toml
   [auth]
   required = true                                        # whole app behind the login page
   cookie_secret = "replace-with-32+-random-characters"   # e.g. `openssl rand -hex 32`

   [auth.users.alice]
   password_hash = "pbkdf2_sha256$200000$...$..."
   name = "Alice"
   email = "alice@example.com"

   [auth.users.bob]
   password_hash = "pbkdf2_sha256$200000$...$..."
   name = "Bob"
   ```

3. Use the user in the app:

<!-- compile -->
```d
import streamlitd;

void app(St st)
{
    auto u = st.user;
    st.write("Hello", u.name, "(" ~ u.email ~ ")");
    if (st.button("Log out"))
        st.logout();
}

mixin StreamlitMain!app;
```

## OpenID Connect providers

Register an application with your identity provider. Use
`https://<your-host>/<base-url-path>/oauth2callback` as the redirect URI, then add the
provider:

```toml
[auth]
cookie_secret = "..."
redirect_uri = "https://apps.example.com/sales/oauth2callback"

[auth.google]
label = "Google"
client_id = "1234.apps.googleusercontent.com"
client_secret = "..."
server_metadata_url = "https://accounts.google.com/.well-known/openid-configuration"

[auth.microsoft]
label = "Microsoft"
client_id = "..."
client_secret = "..."
server_metadata_url = "https://login.microsoftonline.com/<tenant-id>/v2.0/.well-known/openid-configuration"

[auth.keycloak]
label = "Company SSO"
client_id = "streamlitd"
client_secret = "..."
server_metadata_url = "https://sso.example.com/realms/<realm>/.well-known/openid-configuration"
scope = "openid profile email"        # optional (this is the default)
```

With exactly one provider, its keys can also go directly into `[auth]` (`client_id`, …). That
provider is then called `default`.

The login flow uses the OIDC **authorization code** flow:

1. The browser goes to `<base>/auth/login?provider=google`.
2. streamlitd redirects to the provider. The request carries a signed `state` and a `nonce`, and
   the nonce is also stored in a short-lived cookie.
3. The provider redirects back to `<base>/oauth2callback?code=...`.
4. streamlitd exchanges the code at the token endpoint (server to server) and checks the ID
   token's issuer, audience, expiry and nonce.
5. It sets the session cookie and redirects to the app.

## In the app

| Code | Meaning |
|---|---|
| `st.user.isLoggedIn` | `true` when a valid login cookie is present |
| `st.user.name`, `.email` | from the provider (or `name`/`email` in `[auth.users.x]`) |
| `st.user.sub` | stable id: the provider's `sub`, or the username for password logins |
| `st.user.provider` | `"password"` or the provider key (`"google"`, ...) |
| `st.user.claims` | all stored claims as `Json` |
| `st.login()` / `st.login("google")` | go to the login page / straight to a provider |
| `st.logout()` | clear the cookie (and go back to the login page if `required`) |

Without `required = true`, the app is public, and you decide what needs a login:

<!-- wrap -->
```d
if (!st.user.isLoggedIn)
{
    st.info("Please log in to see your reports.");
    if (st.button("Log in"))
        st.login();
    st.stop();
}
st.write("Welcome back,", st.user.name);
```

`st.login()` and `st.logout()` raise an error if `[auth]` is not configured.

## Settings

| Key | Default | Meaning |
|---|---|---|
| `required` | `false` | put the whole app (page, WebSocket, media) behind the login; also `--auth-required` |
| `cookie_secret` | | **required**, at least 16 characters; signs the login cookie (HMAC-SHA256) |
| `cookie_days` | 30 | how long a login lasts |
| `redirect_uri` | | required for OIDC; must match the provider registration |
| `users.<name>` | | `password_hash`, optional `name`, `email` |
| `<provider>` | | `client_id`, `client_secret`, `server_metadata_url`, optional `label`, `scope` |

## Security notes

- The login cookie is **HttpOnly**, **SameSite=Lax**, **Secure** on HTTPS (also behind a proxy
  that sends `X-Forwarded-Proto: https`), and signed with `cookie_secret`. Changing the secret
  logs everybody out.
- The cookie stores a small set of claims (`sub`, `name`, `email`, `picture`, `provider`) and an
  expiry time; it contains no tokens.
- Password hashes use PBKDF2-HMAC-SHA256 with 200,000 iterations and a random salt. They are verified on a
  worker thread, and unknown usernames take the same time as wrong passwords.
- Put the app behind HTTPS in production, so cookies and passwords are never sent in clear text.
- streamlitd does not rate-limit login attempts. Use your reverse proxy for that, e.g. nginx
  `limit_req` on `/auth/login`.
