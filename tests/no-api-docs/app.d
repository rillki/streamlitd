/// Built by run-tests.sh with the dub version StreamlitdNoApiDocs: registerApi still registers the
/// routes, but no OpenAPI generator or Swagger UI is compiled in.
import streamlitd;
import vibe.web.rest;

@path("/api")
interface PingApi
{
@safe:
	@path("/ping") @method(HTTPMethod.GET) @apiDoc("Ping")
	string ping();
}

class Ping : PingApi
{
	string ping() @safe { return "pong"; }
}

static assert(!apiDocsCompiledIn, "the StreamlitdNoApiDocs version did not reach the streamlitd library");

void routes(URLRouter r) { r.registerApi(new Ping); }

void app(St st) { st.write("no API docs in this build"); }

mixin StreamlitMain!(app, routes);
