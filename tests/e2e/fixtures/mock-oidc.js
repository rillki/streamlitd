// Tiny mock OpenID Connect provider for e2e tests (authorization code flow, auto-approve).
const http = require("http");
const { URL } = require("url");
const port = +(process.env.PORT || 8790);
const issuer = `http://127.0.0.1:${port}`;
const codes = new Map();
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");

http.createServer((req, res) => {
  const u = new URL(req.url, issuer);
  if (u.pathname === "/.well-known/openid-configuration") {
    res.setHeader("Content-Type", "application/json");
    return res.end(JSON.stringify({ issuer, authorization_endpoint: issuer + "/authorize", token_endpoint: issuer + "/token" }));
  }
  if (u.pathname === "/authorize") {
    const code = Math.random().toString(36).slice(2);
    codes.set(code, { nonce: u.searchParams.get("nonce"), clientId: u.searchParams.get("client_id") });
    const back = new URL(u.searchParams.get("redirect_uri"));
    back.searchParams.set("code", code);
    back.searchParams.set("state", u.searchParams.get("state"));
    res.writeHead(302, { Location: back.toString() });
    return res.end();
  }
  if (u.pathname === "/token" && req.method === "POST") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      const p = new URLSearchParams(body);
      const c = codes.get(p.get("code"));
      if (!c || p.get("client_secret") !== "mock-secret") { res.writeHead(400); return res.end("{}"); }
      codes.delete(p.get("code"));
      const now = Math.floor(Date.now() / 1000);
      const idToken = b64({ alg: "none" }) + "." + b64({ iss: issuer, aud: c.clientId, sub: "mock-1", name: "Mock User",
        email: "mock@example.com", nonce: c.nonce, iat: now, exp: now + 600 }) + ".";
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify({ access_token: "at", token_type: "Bearer", id_token: idToken }));
    });
    return;
  }
  if (u.pathname === "/health") return res.end("ok");
  res.writeHead(404); res.end();
}).listen(port, "127.0.0.1");
