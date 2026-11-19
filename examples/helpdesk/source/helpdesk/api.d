/// The JSON API next to the UI: the same store, the same login cookie and roles.
module helpdesk.api;

import streamlitd;
import vibe.data.json;
import helpdesk.store;

void routes(URLRouter r)
{
	// GET /api/tickets: every signed-in user
	r.get("/api/tickets", (HTTPServerRequest req, HTTPServerResponse res) {
		requireUser(req, res);
		res.writeJsonBody(serializeToJson(store.tickets));
	});
	// POST /api/tickets {"title", "customer", "priority"}: agents only; open pages update at once.
	// Everything from the request is checked: a client is not the UI and may send anything.
	r.post("/api/tickets", (HTTPServerRequest req, HTTPServerResponse res) {
		auto u = requireRole(req, res, "agent");
		auto j = req.json;
		if (j.type != Json.Type.object)
			throw new HTTPStatusException(HTTPStatus.badRequest, "expected a JSON object");
		string field(string name, string def)
		{
			if (name !in j)
				return def;
			if (j[name].type != Json.Type.string)
				throw new HTTPStatusException(HTTPStatus.badRequest, name ~ " must be a string");
			return j[name].get!string;
		}
		auto title = field("title", null), customer = field("customer", "acme"), priority = field("priority", "normal");
		if (auto p = store.problemOf(title, customer, priority))
			throw new HTTPStatusException(HTTPStatus.badRequest, p);
		auto t = store.add(u.username, title, customer, priority);
		res.statusCode = HTTPStatus.created;
		res.writeJsonBody(serializeToJson(t));
	});
}
