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

echo "== unit tests of the larger examples =="
for ex in helpdesk planning todo gantt monitor; do
	( cd "examples/$ex" && dub test --compiler="$DC" -q ) >"$log" 2>&1 || { grep -E "Error|Assertion|FAILED" "$log" | grep -v Deprecation | tail -20; echo "examples/$ex: dub test failed"; exit 1; }
	echo "ok: examples/$ex"
done

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
( cd tests/e2e && { [ -d node_modules ] || npm install; } && DC="$DC" npx playwright test ) || exit 1

if [ "${LOAD:-1}" != "0" ]; then
	echo "== load test (many sessions at once; LOAD=0 skips it) =="
	( cd tests/load && dub build --compiler="$DC" -q ) || { echo "load test app build failed"; exit 1; }
	node tests/load/load.mjs --sessions 100 --threads 2 2>&1 | grep -v -e "FD [0-9]" -e "leaking eventcore" -e "EventCoreLeakTrace" -e "tasks running at exit"
	[ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
fi
