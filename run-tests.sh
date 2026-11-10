#!/usr/bin/env bash
# Runs D unit tests (incl. headless AppTest suites) and Playwright end-to-end tests.
set -uo pipefail
cd "$(dirname "$0")"
DC="${DC:-ldc2}"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

echo "== dub test =="
dub test --compiler="$DC" >"$log" 2>&1
status=$?
{ grep -E "^(source|tests)/|Error|Assertion|modules passed|failed" "$log" | grep -v Deprecation || true; } | tail -20
if [ $status -ne 0 ]; then
	echo "dub test failed (exit $status)"
	exit $status
fi

echo "== build without API docs (StreamlitdNoApiDocs) =="
( cd tests/no-api-docs && dub build --compiler="$DC" -q ) || { echo "no-api-docs build failed"; exit 1; }
if grep -a -q SwaggerUIBundle tests/no-api-docs/no-api-docs; then
	echo "Swagger UI is still embedded in a StreamlitdNoApiDocs build"
	exit 1
fi
echo "ok: no generator, no Swagger UI"

echo "== doc snippets =="
DC="$DC" python3 tools/check_doc_snippets.py || exit 1

echo "== e2e (Playwright) =="
cd tests/e2e
[ -d node_modules ] || npm install || exit 1
DC="$DC" npx playwright test
