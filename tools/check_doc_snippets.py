#!/usr/bin/env python3
"""Compile the D code snippets in docs/*.md and check relative links/images in docs and README.

Every ```d block must be preceded by one of these markers:
  <!-- compile -->     a complete module (`mixin StreamlitMain!...` is stripped)
  <!-- wrap -->        statements, wrapped into `void app(St st) { ... }`
  <!-- no-compile -->  an excerpt that depends on surrounding code
docs/api-reference.md (generated signatures) is exempt.
"""
import glob, json, os, re, shutil, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DOCS = os.path.join(ROOT, "docs")
WORK = os.path.join(ROOT, "tests", "doc-snippets")
PRELUDE = """import streamlitd;
import std.conv : to;
import std.format : format;
import std.algorithm : canFind, map, sort;
import std.array : array, join;
"""
BLOCK = re.compile(r"(?:^|\n)(?P<marker><!--\s*(?P<kind>compile|wrap|no-compile)\s*-->\s*\n)?```d\n(?P<code>.*?)\n```", re.S)


def collect():
    snippets, problems = [], []
    for md in sorted(glob.glob(os.path.join(DOCS, "*.md"))):
        if md.endswith("api-reference.md"):
            continue
        text = open(md, encoding="utf-8").read()
        for m in BLOCK.finditer(text):
            line = text[: m.start("code")].count("\n") + 1
            kind = m.group("kind")
            where = f"{os.path.relpath(md, ROOT)}:{line}"
            if kind is None:
                problems.append(f"{where}: D block without a compile/wrap/no-compile marker")
            elif kind != "no-compile":
                snippets.append((where, kind, m.group("code"), line))
    return snippets, problems


def build(snippets):
    if os.path.exists(WORK):
        shutil.rmtree(WORK)
    os.makedirs(os.path.join(WORK, "source"))
    json.dump({"name": "doc-snippets", "targetType": "executable",
               "dependencies": {"streamlitd": {"path": "../.."}}}, open(os.path.join(WORK, "dub.json"), "w"), indent=1)
    origin = {}
    for i, (where, kind, code, line) in enumerate(snippets):
        name = f"snip{i:03d}"
        code = re.sub(r"^\s*mixin StreamlitMain!\w+;.*$", "", code, flags=re.M)
        code = re.sub(r"^\s*int main\(\)", "int snippetMain()", code, flags=re.M)
        if kind == "wrap":
            body = "\n".join("\t" + l for l in code.split("\n"))
            src = f"module {name};\n{PRELUDE}\nvoid app(St st)\n{{\n{body}\n}}\n"
            offset = src.split("\n").index("{") + 2  # first code line number in the file
        else:
            src = f"module {name};\n{PRELUDE}\n{code}\n"
            offset = len(PRELUDE.split("\n")) + 1
        open(os.path.join(WORK, "source", name + ".d"), "w", encoding="utf-8").write(src)
        origin[name] = (where, line, offset)
    open(os.path.join(WORK, "source", "app.d"), "w").write("void main() {}\n")
    dc = os.environ.get("DC", "ldc2")
    r = subprocess.run(["dub", "build", "--compiler=" + dc, "-q", "--root", WORK], capture_output=True, text=True)
    errors = []
    for l in (r.stdout + r.stderr).split("\n"):
        m = re.match(r"^(?:.*/)?source/(snip\d+)\.d\((\d+),(\d+)\): (Error.*)$", l)
        if m:
            where, docline, offset = origin[m.group(1)]
            errors.append(f"{where.split(':')[0]}:{docline + int(m.group(2)) - offset}: {m.group(4)}")
        elif "Error" in l and "Deprecation" not in l and "snip" not in l and l.strip():
            errors.append(l)
    return r.returncode, errors


LINK = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")


def check_links():
    bad = []
    files = glob.glob(os.path.join(DOCS, "*.md")) + [os.path.join(ROOT, "README.md")]
    for md in files:
        text = open(md, encoding="utf-8").read()
        text = re.sub(r"```.*?```", "", text, flags=re.S)
        for m in LINK.finditer(text):
            target = m.group(1)
            if re.match(r"^(https?:|mailto:|#)", target):
                continue
            path = target.split("#")[0]
            if not os.path.exists(os.path.normpath(os.path.join(os.path.dirname(md), path))):
                bad.append(f"{os.path.relpath(md, ROOT)}: broken link {target}")
    return bad


def main():
    snippets, problems = collect()
    links = check_links()
    print(f"doc snippets: {len(snippets)} to compile")
    code, errors = build(snippets)
    for p in problems + links + errors:
        print("  " + p)
    ok = not problems and not links and code == 0
    print("doc snippets OK" if ok else "doc snippets FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
