/* streamlitd frontend: renders element deltas received over a WebSocket. */
(function () {
  "use strict";

  // ------------------------------------------------------------------ state
  // The server injects <base href="/<baseUrlPath>/">; every URL is resolved against it.
  const BASE = new URL(document.baseURI).pathname.replace(/\/?$/, "/");
  const pageFromLocation = () => {
    let p = location.pathname;
    if (p.startsWith(BASE)) p = p.slice(BASE.length); else p = p.replace(/^\/+/, "");
    return decodeURIComponent(p.replace(/\/+$/, ""));
  };
  const S = {
    ws: null,
    sessionId: null,
    running: false,
    runId: 0,
    roots: {},
    forms: {},          // formId -> { values: {id: value}, submitId, node }
    page: pageFromLocation(),
    staleTimer: null,
    reconnectDelay: 500,
    everConnected: false,
    navVisible: false,
    pageConfig: {},
    vegaPromise: null,
  };

  const $ = (sel, root) => (root || document).querySelector(sel);
  function h(tag, attrs, ...children) {
    const e = document.createElement(tag);
    if (attrs) for (const k in attrs) {
      const v = attrs[k];
      if (v === null || v === undefined || v === false) continue;
      if (k === "class") e.className = v;
      else if (k === "text") e.textContent = v;
      else if (k === "html") e.innerHTML = v;
      else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
      else if (k === "style" && typeof v === "object") Object.assign(e.style, v);
      else e.setAttribute(k, v === true ? "" : v);
    }
    for (const c of children.flat()) {
      if (c === null || c === undefined || c === false) continue;
      e.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    }
    return e;
  }
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  // ------------------------------------------------------------------ markdown
  const COLOR_RE = /:(red|blue|green|orange|violet|gray|grey|rainbow|primary)\[([^\]]*)\]/g;
  const BG_RE = /:(red|blue|green)-background\[([^\]]*)\]/g;
  function markedOpts(allowHtml) {
    return {
      gfm: true, breaks: false, async: false,
      renderer: allowHtml ? undefined : Object.assign(new marked.Renderer(), {
        html(token) { const t = typeof token === "object" ? (token.text || token.raw || "") : token; return esc(t); },
      }),
    };
  }
  function postMd(html) {
    return html.replace(BG_RE, '<span class="st-bg-$1">$2</span>').replace(COLOR_RE, '<span class="st-color-$1">$2</span>');
  }
  // marked does not sanitize URLs: neutralise script-capable schemes unless HTML is explicitly allowed
  const BAD_URL_RE = /(href|src)\s*=\s*"\s*(?:javascript|vbscript|data:text\/html)[^"]*"/gi;
  function safeUrls(html, allowHtml) { return allowHtml ? html : html.replace(BAD_URL_RE, '$1="#"'); }
  // $inline$ / $$display$$ math: pulled out before markdown (outside code spans) and
  // rendered with KaTeX after insertion (see typeset()).
  function extractMath(text) {
    const math = [];
    const parts = String(text).split(/(```[\s\S]*?```|`[^`\n]*`)/);
    for (let i = 0; i < parts.length; i += 2) {
      parts[i] = parts[i]
        .replace(/\$\$([\s\S]+?)\$\$/g, (m, tex) => { math.push([tex, true]); return "@@STMATH" + (math.length - 1) + "@@"; })
        .replace(/(^|[^\\$])\$(?!\s)([^$\n]+?)(?<!\s)\$(?!\d)/g, (m, pre, tex) => { math.push([tex, false]); return pre + "@@STMATH" + (math.length - 1) + "@@"; });
    }
    return { text: parts.join(""), math };
  }
  function restoreMath(html, math) {
    if (!math.length) return html;
    return html.replace(/@@STMATH(\d+)@@/g, (m, i) => {
      const [tex, display] = math[+i];
      return '<span class="st-math" data-display="' + (display ? "1" : "0") + '" data-tex="' + esc(tex) + '">' + esc(tex) + "</span>";
    });
  }
  function md(text, allowHtml) {
    if (text === null || text === undefined) return "";
    try {
      const m = extractMath(text);
      const r = marked.parse(m.text, markedOpts(allowHtml));
      return restoreMath(safeUrls(postMd(r), allowHtml), m.math);
    } catch (e) { return esc(text); }
  }
  function mdInline(text, allowHtml) {
    if (text === null || text === undefined) return "";
    try {
      const m = extractMath(text);
      return restoreMath(safeUrls(postMd(marked.parseInline(m.text, markedOpts(allowHtml))), allowHtml), m.math);
    } catch (e) { return esc(text); }
  }
  function mdEl(text, cls, allowHtml) {
    return h("div", { class: "markdown" + (cls ? " " + cls : ""), html: md(text, allowHtml) });
  }

  // ------------------------------------------------------------------ connection
  function wsUrl() {
    const u = new URL("_stcore/ws", document.baseURI);
    u.protocol = u.protocol === "https:" ? "wss:" : "ws:";
    return u.toString();
  }

  function connect() {
    const ws = new WebSocket(wsUrl());
    S.ws = ws;
    ws.onopen = () => {
      S.reconnectDelay = 500;
      S.everConnected = true;
      $("#stConnection").hidden = true;
      sendRerun({});
    };
    ws.onmessage = (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch (e) { return; }
      handleMessage(msg);
    };
    ws.onclose = () => {
      if (S.ws !== ws) return;
      setRunning(false);
      $("#stConnection").hidden = false;
      setTimeout(connect, S.reconnectDelay);
      S.reconnectDelay = Math.min(S.reconnectDelay * 2, 5000);
    };
  }

  function queryObj() {
    const q = {};
    new URLSearchParams(location.search).forEach((v, k) => { q[k] = v; });
    return q;
  }

  function send(msg) {
    if (S.ws && S.ws.readyState === WebSocket.OPEN) S.ws.send(JSON.stringify(msg));
  }

  function sendRerun(updates, trigger, triggerValue, fragment) {
    const m = { type: "rerun", updates: updates || {}, page: S.page, query: queryObj() };
    if (trigger) { m.trigger = trigger; m.triggerValue = triggerValue === undefined ? true : triggerValue; }
    if (fragment) m.fragment = fragment;
    send(m);
  }

  // A widget changed its value (widgets inside st.fragment rerun only their fragment).
  function widgetChanged(el, value) {
    if (el.form && S.forms[el.form]) {
      S.forms[el.form].values[el.id] = value;
      return;
    }
    sendRerun({ [el.id]: value }, null, undefined, el.fragment);
  }

  function triggerWidget(el, value) {
    sendRerun({}, el.id, value === undefined ? true : value, el.fragment);
  }

  function submitForm(formId, submitId) {
    const f = S.forms[formId];
    if (!f) return;
    const sid = submitId || f.submitId;
    if (!sid) return;
    const updates = Object.assign({}, f.values);
    f.values = {};
    // pick up values of focused text inputs that have not been committed yet
    sendRerun(updates, sid, true, f.fragment);
  }

  // ------------------------------------------------------------------ messages
  function handleMessage(msg) {
    switch (msg.type) {
      case "new_session":
        S.sessionId = msg.sessionId;
        if (msg.themes) T.presets = msg.themes;
        if (msg.designs) T.designs = msg.designs;
        if (msg.theme) T.server = msg.theme;
        applyTheme();
        break;
      case "set_theme":
        T.app = msg;
        applyTheme();
        break;
      case "script_started":
        S.runId = msg.run;
        onScriptStarted(msg);
        break;
      case "delta":
        applyDelta(msg.path, msg.el);
        break;
      case "script_finished":
        onScriptFinished(msg.status, msg);
        break;
      case "logo":
        renderLogo(msg);
        break;
      case "navigate":
        location.href = new URL(msg.url, document.baseURI).toString();
        break;
      case "page_config":
        applyPageConfig(msg);
        break;
      case "toast":
        showToast(msg.body, msg.icon);
        break;
      case "effect":
        showEffect(msg.name);
        break;
      case "navigation":
        renderNav(msg);
        break;
      case "set_page":
        setPage(msg.urlPath, false);
        break;
      case "query_params": {
        const u = new URL(location.href);
        u.search = new URLSearchParams(msg.params || {}).toString();
        history.replaceState(history.state, "", u);
        break;
      }
    }
  }

  function setRunning(r) {
    S.running = r;
    const st = $("#stStatus");
    st.classList.toggle("running", r);
    st.textContent = r ? "Running..." : "";
    document.body.dataset.running = r ? "1" : "0";
  }

  function forEachNode(node, fn) {
    for (const c of node.children) { if (!c) continue; fn(c); forEachNode(c, fn); }
  }

  function nodeAt(path) {
    let n = S.roots[path[0]];
    for (let i = 1; n && i < path.length; i++) n = n.children[path[i]];
    return n || null;
  }

  // The scope of the current run: all roots, or only the subtree of a fragment.
  function runScopes() {
    if (S.fragmentRun) return S.fragmentNode ? [S.fragmentNode] : []; // unknown fragment: touch nothing
    return Object.values(S.roots);
  }

  function onScriptStarted(msg) {
    setRunning(true);
    S.fragmentRun = !!(msg && msg.fragment);
    S.fragmentNode = S.fragmentRun ? nodeAt(msg.path) : null;
    if (!S.fragmentRun) { S.navSeen = false; S.iconSetThisRun = false; S.navIcon = null; }
    for (const r of runScopes()) forEachNode(r, (n) => { n.fresh = false; });
    clearTimeout(S.staleTimer);
    S.staleTimer = setTimeout(() => {
      if (!S.running) return;
      for (const r of runScopes()) forEachNode(r, (n) => { if (!n.fresh) n.wrap.classList.add("stale"); });
    }, 400);
  }

  // ---- favicon: app icon set this run > current page icon (multipage) > default / --favicon
  const defaultIcons = Array.from(document.querySelectorAll("link[data-default-icon]")).map((l) => ({ el: l, href: l.getAttribute("href"), type: l.getAttribute("type") }));
  function iconHref(icon) {
    // an emoji becomes an SVG; URLs and app-served files (_media/..., paths) are used as they are
    if (/^(https?:|data:|\/|_media\/)/.test(icon) || /\.(svg|png|ico|jpe?g|gif|webp)(\?.*)?$/i.test(icon)) return icon;
    return "data:image/svg+xml," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><text y=".9em" font-size="90">' + esc(icon) + "</text></svg>");
  }
  function setFavicon(icon) {
    const href = icon ? iconHref(icon) : null;
    if (S.faviconHref === href) return;
    S.faviconHref = href;
    defaultIcons.forEach((d) => {
      if (href) { d.el.setAttribute("href", href); d.el.removeAttribute("type"); }
      else { d.el.setAttribute("href", d.href); if (d.type) d.el.setAttribute("type", d.type); }
    });
    document.documentElement.dataset.favicon = icon ? "custom" : "default";
  }

  function onScriptFinished(status, msg) {
    clearTimeout(S.staleTimer);
    setRunning(false);
    if (status !== "rerun") {
      for (const r of runScopes()) prune(r);
      if (!S.fragmentRun && !S.navSeen) { S.navVisible = false; $("#stNav").innerHTML = ""; }
    }
    for (const r of runScopes()) forEachNode(r, (n) => n.wrap.classList.remove("stale"));
    if (!S.fragmentRun && status !== "rerun" && !S.iconSetThisRun) setFavicon(S.navIcon || null);
    S.fragmentNode = null;
    S.fragmentRun = false;
    updateSidebarVisibility();
    document.body.dataset.runs = String((+document.body.dataset.runs || 0) + 1);
  }

  function prune(node) {
    let last = -1;
    node.children.forEach((c, i) => { if (c && c.fresh) last = i; });
    for (let i = node.children.length - 1; i > last; i--) {
      const c = node.children[i];
      if (c) destroyNode(c);
    }
    node.children.length = last + 1;
    node.children.forEach((c, i) => {
      if (!c) return;
      if (!c.fresh) { resetNode(c); c.fresh = true; }
      else prune(c);
    });
  }

  function destroyNode(n) {
    forEachNode(n, (c) => c.destroy && c.destroy());
    if (n.destroy) n.destroy();
    n.wrap.remove();
  }

  function resetNode(n) {
    forEachNode(n, (c) => c.destroy && c.destroy());
    if (n.destroy) n.destroy();
    n.wrap.innerHTML = "";
    n.wrap.dataset.kind = "empty";
    n.children = [];
    n.el = { kind: "empty" };
    n.inner = null;
  }

  // ------------------------------------------------------------------ tree
  function makeRoot(i) {
    const dom = document.getElementById("stRoot-" + i);
    return { children: [], inner: dom, wrap: dom, isRoot: true, el: { kind: "block", block: "vertical" } };
  }

  function containerFor(parent, idx) {
    if (parent.containerFor) return parent.containerFor(idx);
    return parent.inner || parent.wrap;
  }

  function ensureChild(parent, idx) {
    for (let i = parent.children.length; i <= idx; i++) {
      const wrap = h("div", { class: "element-container", "data-kind": "empty" });
      const n = { children: [], wrap, el: { kind: "empty" }, fresh: true, parent, index: i };
      containerFor(parent, i).appendChild(wrap);
      parent.children[i] = n;
    }
    if (!parent.children[idx]) {
      const wrap = h("div", { class: "element-container", "data-kind": "empty" });
      const n = { children: [], wrap, el: { kind: "empty" }, fresh: true, parent, index: idx };
      containerFor(parent, idx).appendChild(wrap);
      parent.children[idx] = n;
    }
    return parent.children[idx];
  }

  function applyDelta(path, el) {
    const r = path[0];
    if (!S.roots[r]) S.roots[r] = makeRoot(r);
    let parent = S.roots[r];
    for (let i = 1; i < path.length - 1; i++) {
      parent = ensureChild(parent, path[i]);
      parent.fresh = true;
      parent.wrap.classList.remove("stale");
    }
    const idx = path[path.length - 1];
    const node = ensureChild(parent, idx);
    renderInto(node, el);
    node.fresh = true;
    node.wrap.classList.remove("stale");
    if (r !== 0) updateSidebarVisibility();
  }

  function propsKey(el) {
    const c = Object.assign({}, el);
    delete c.value;
    return JSON.stringify(c);
  }

  function renderInto(node, el) {
    // a widget inside a form keeps its not-yet-submitted value across reruns
    if (el.form && el.id && S.forms[el.form] && Object.prototype.hasOwnProperty.call(S.forms[el.form].values, el.id)) {
      el = Object.assign({}, el, { value: S.forms[el.form].values[el.id] });
    }
    const old = node.el || {};
    const sameKind = old.kind === el.kind && (el.kind !== "block" || old.block === el.block) && (old.id || null) === (el.id || null);
    if (sameKind && el.kind === "block") {
      // keep the block (and its children) — just update props
      if (node.fresh && node.wasRenderedThisRun === S.runId && !el.update) {
        // block re-emitted within the same run: start over with its children
        for (const c of node.children) if (c) destroyNode(c);
        node.children = [];
      }
      if (node.update) node.update(el);
      node.el = el;
      node.wasRenderedThisRun = S.runId;
      return;
    }
    if (sameKind && node.update && propsKey(old) === propsKey(el)) {
      node.update(el);
      node.el = el;
      node.wasRenderedThisRun = S.runId;
      return;
    }
    // charts and custom components update in place (a component keeps its iframe and state)
    if (sameKind && (el.kind === "vega_lite" || el.kind === "plotly" || el.kind === "component") && node.update) {
      node.update(el);
      node.el = el;
      return;
    }
    // full re-render
    const hadFocus = node.wrap.contains(document.activeElement);
    for (const c of node.children) if (c) destroyNode(c);
    if (node.destroy) node.destroy();
    node.children = [];
    node.update = null; node.destroy = null; node.containerFor = null; node.inner = null;
    node.wrap.innerHTML = "";
    node.wrap.dataset.kind = el.kind === "block" ? "block-" + el.block : el.kind;
    node.el = el;
    node.wasRenderedThisRun = S.runId;
    const r = el.kind === "block" ? BLOCKS[el.block] : RENDERERS[el.kind];
    if (r) {
      try { r(node, el); } catch (e) { console.error(e); node.wrap.appendChild(h("div", { class: "exception", text: "Render error: " + e })); }
    } else {
      node.wrap.appendChild(h("div", { class: "alert alert-warning", text: "Unknown element: " + el.kind }));
    }
    if (hadFocus) {
      const f = node.wrap.querySelector("input,textarea,select");
      if (f) f.focus();
    }
    typeset(node.wrap);
  }

  // ------------------------------------------------------------------ helpers for widgets
  function labelEl(el, forId) {
    const vis = el.labelVisibility || "visible";
    const l = h("label", { class: "widget-label" + (vis === "hidden" ? " hidden" : vis === "collapsed" ? " collapsed" : ""), for: forId || null });
    l.innerHTML = mdInline(el.label || "");
    if (el.help) l.appendChild(h("span", { class: "help", title: el.help, text: "?" }));
    return l;
  }
  let uid = 0;
  const nextId = () => "st-w" + (++uid);
  function widgetBox(node, el, cls) {
    const box = h("div", { class: "widget " + (cls || "") + (el.disabled ? " disabled" : ""), "data-testid": "st-" + el.kind, "data-label": el.label || "" });
    node.wrap.appendChild(box);
    return box;
  }
  function fmtNum(v, el) {
    if (v === null || v === undefined) return "";
    if (el && el.format) {
      const m = /%(?:\.(\d+))?([dfie])/.exec(el.format);
      if (m) {
        let s;
        if (m[2] === "d" || m[2] === "i") s = String(Math.round(v));
        else if (m[2] === "e") s = Number(v).toExponential(m[1] ? +m[1] : 6);
        else s = Number(v).toFixed(m[1] ? +m[1] : 6);
        return el.format.replace(m[0], s);
      }
    }
    if (el && el.isInt) return String(Math.round(v));
    if (typeof v === "number" && !Number.isInteger(v)) {
      const step = el && el.step ? el.step : 0.01;
      const dec = Math.max(0, Math.min(10, Math.ceil(-Math.log10(step))));
      return Number(v).toFixed(dec);
    }
    return String(v);
  }
  function btnClass(el) {
    return "st-btn" + (el.type === "primary" ? " primary" : el.type === "tertiary" ? " tertiary" : "") + (el.fullWidth ? " full" : "");
  }
  function btnContent(el) {
    const c = [];
    if (el.icon) c.push(h("span", { class: "btn-icon", text: el.icon }));
    c.push(h("span", { html: mdInline(el.label || "") }));
    return c;
  }

  // ------------------------------------------------------------------ blocks
  const BLOCKS = {
    vertical(node, el) {
      const d = h("div", { class: "block-vertical" + (el.border ? " bordered" : "") + (el.height ? " scroll" : "") });
      if (el.height) d.style.height = el.height + "px";
      node.wrap.appendChild(d);
      node.inner = d;
      node.update = (e) => {
        d.classList.toggle("bordered", !!e.border);
        if (e.height) d.style.height = e.height + "px";
      };
    },
    horizontal(node, el) {
      const d = h("div", { class: "block-horizontal gap-" + (el.gap || "small") + " align-" + (el.align || "top") });
      node.wrap.appendChild(d);
      node.inner = d;
    },
    column(node, el) {
      const d = h("div", { class: "block-column" + (el.border ? " bordered" : "") });
      node.wrap.style.flex = (el.weight || 1) + " 1 0";
      node.wrap.style.minWidth = "0";
      node.wrap.classList.add("column-wrap");
      node.wrap.appendChild(d);
      node.inner = d;
      node.update = (e) => { node.wrap.style.flex = (e.weight || 1) + " 1 0"; };
    },
    expander(node, el) {
      const det = h("details", { class: "expander", open: el.expanded || null, "data-testid": "st-expander" });
      const sum = h("summary", null, el.icon ? h("span", { text: el.icon }) : null, h("span", { html: mdInline(el.label) }));
      const inner = h("div", { class: "block-vertical" });
      det.append(sum, inner);
      node.wrap.appendChild(det);
      node.inner = inner;
      node.update = (e) => { sum.lastChild.innerHTML = mdInline(e.label); };
    },
    popover(node, el) {
      const wrap = h("div", { class: "popover" });
      const btn = h("button", { class: "st-btn" + (el.fullWidth ? " full" : ""), disabled: el.disabled || null, title: el.help || null }, h("span", { html: mdInline(el.label) }), h("span", { text: " ⌄" }));
      const panel = h("div", { class: "popover-panel", hidden: true });
      const inner = h("div", { class: "block-vertical" });
      panel.appendChild(inner);
      btn.addEventListener("click", (ev) => { ev.stopPropagation(); panel.hidden = !panel.hidden; });
      const close = (ev) => { if (!wrap.contains(ev.target) && !StUI.inPopup(ev.target)) panel.hidden = true; };
      document.addEventListener("click", close);
      wrap.append(btn, panel);
      node.wrap.appendChild(wrap);
      node.inner = inner;
      node.destroy = () => document.removeEventListener("click", close);
    },
    tabs(node, el) {
      const d = h("div", { class: "tabs" });
      const list = h("div", { class: "tab-list", role: "tablist" });
      const panels = h("div", { class: "tab-panels" });
      d.append(list, panels);
      node.wrap.appendChild(d);
      node.active = 0;
      const build = (labels) => {
        list.innerHTML = "";
        labels.forEach((l, i) => {
          const b = h("button", { class: "tab-btn" + (i === node.active ? " active" : ""), role: "tab", html: mdInline(l) });
          b.addEventListener("click", () => { node.active = i; refresh(); });
          list.appendChild(b);
        });
      };
      const refresh = () => {
        Array.from(list.children).forEach((b, i) => b.classList.toggle("active", i === node.active));
        node.children.forEach((c, i) => { if (c) c.wrap.hidden = i !== node.active; });
      };
      build(el.labels || []);
      node.containerFor = (idx) => panels;
      node.refreshTabs = refresh;
      node.update = (e) => {
        if (JSON.stringify(e.labels) !== JSON.stringify(node.el.labels)) {
          if (node.active >= e.labels.length) node.active = 0;
          build(e.labels);
        }
      };
    },
    tab(node, el) {
      const d = h("div", { class: "block-vertical tab-panel" });
      node.wrap.appendChild(d);
      node.inner = d;
      const p = node.parent;
      node.wrap.hidden = p && p.active !== undefined ? node.index !== p.active : false;
    },
    form(node, el) {
      const d = h("form", { class: "form block-vertical" + (el.border === false ? " no-border" : ""), "data-testid": "st-form" });
      d.addEventListener("submit", (ev) => { ev.preventDefault(); });
      node.wrap.appendChild(d);
      node.inner = d;
      if (!S.forms[el.formId]) S.forms[el.formId] = { values: {}, submitId: null };
      S.forms[el.formId].fragment = el.fragment || null;
      S.forms[el.formId].enterToSubmit = el.enterToSubmit !== false;
    },
    fragment(node, el) {
      const d = h("div", { class: "block-vertical fragment", "data-testid": "st-fragment" });
      node.wrap.appendChild(d);
      node.inner = d;
    },
    dialog(node, el) {
      const overlay = h("div", { class: "dialog-overlay", "data-testid": "st-dialog" });
      const box = h("div", { class: "dialog-box " + (el.width === "large" ? "large" : "small"), role: "dialog", "aria-modal": "true", "aria-label": el.title || "" });
      const head = h("div", { class: "dialog-head" }, h("h3", { html: mdInline(el.title || "") }));
      const close = () => {
        document.removeEventListener("keydown", onKey);
        const p = node.parent;
        resetNode(node);
        if (p) node.el = { kind: "empty" };
      };
      const onKey = (ev) => { if (ev.key === "Escape" && el.dismissible !== false) close(); };
      if (el.dismissible !== false) {
        const x = h("button", { type: "button", class: "icon-btn", "aria-label": "Close", text: "\u00D7" });
        x.addEventListener("click", close);
        head.appendChild(x);
        overlay.addEventListener("mousedown", (ev) => { if (ev.target === overlay) close(); });
        document.addEventListener("keydown", onKey);
      }
      const inner = h("div", { class: "block-vertical" });
      box.append(head, inner);
      overlay.appendChild(box);
      node.wrap.appendChild(overlay);
      node.inner = inner;
      node.destroy = () => document.removeEventListener("keydown", onKey);
      node.update = (e) => { head.firstChild.innerHTML = mdInline(e.title || ""); };
    },
    status(node, el) {
      const icons = { running: null, complete: "\u2705", error: "\u274C" };
      const det = h("details", { class: "expander status", open: el.expanded || null, "data-testid": "st-status-container" });
      const icon = h("span", { class: "status-icon" });
      const label = h("span");
      const sum = h("summary", null, icon, label);
      const inner = h("div", { class: "block-vertical" });
      det.append(sum, inner);
      node.wrap.appendChild(det);
      node.inner = inner;
      const draw = (e) => {
        label.innerHTML = mdInline(e.label || "");
        icon.innerHTML = "";
        if (e.state === "running" || !icons[e.state]) icon.appendChild(h("span", { class: "spinner-icon small" }));
        else icon.textContent = icons[e.state];
        det.dataset.state = e.state || "running";
        if (e.update) det.open = !!e.expanded;
      };
      draw(el);
      node.update = draw;
    },
    chat_message(node, el) {
      const name = el.name || "";
      const avatar = el.avatar || (name === "user" ? "\u{1F9D1}" : name === "assistant" ? "\u{1F916}" : (name[0] || "?").toUpperCase());
      const d = h("div", { class: "chat-message " + (name === "user" ? "user" : name === "assistant" ? "assistant" : ""), "data-testid": "st-chat-message" });
      const inner = h("div", { class: "block-vertical" });
      d.append(h("div", { class: "chat-avatar", text: avatar }), inner);
      node.wrap.appendChild(d);
      node.inner = inner;
    },
  };

  // ------------------------------------------------------------------ elements
  const RENDERERS = {
    empty() {},

    heading(node, el) {
      const tag = "h" + (el.level || 1);
      const anchorId = el.anchor || String(el.body || "").toLowerCase().replace(/[^\w]+/g, "-").replace(/^-|-$/g, "");
      const hd = h(tag, { id: anchorId });
      hd.innerHTML = mdInline(el.body);
      if (el.help) hd.appendChild(h("span", { class: "help", title: el.help, text: "?" }));
      hd.appendChild(h("a", { class: "anchor", href: "#" + anchorId, text: "\u{1F517}" }));
      const box = h("div", { class: "heading" }, hd);
      if (el.divider) {
        const colors = { blue: "#1c83e1", green: "#21c354", orange: "#ff8700", red: "#ff2b2b", violet: "#803df5", gray: "#808495", grey: "#808495" };
        const bg = el.divider === "rainbow" || el.divider === "true" ? "linear-gradient(to right, #ff4b4b, #ffa421, #ffe312, #21c354, #1c83e1, #803df5)" : (colors[el.divider] || el.divider);
        box.appendChild(h("hr", { class: "heading-divider", style: { background: bg } }));
      }
      node.wrap.appendChild(box);
    },

    markdown(node, el) {
      const m = mdEl(el.body, el.caption ? "caption" : "", el.allowHtml);
      m.dataset.testid = el.caption ? "st-caption" : "st-markdown";
      node.wrap.appendChild(m);
      if (el.help) m.appendChild(h("span", { class: "help", title: el.help, text: "?" }));
    },

    text(node, el) {
      node.wrap.appendChild(h("pre", { class: "st-text", text: el.body, title: el.help || null }));
    },

    html(node, el) {
      node.wrap.appendChild(h("div", { class: "st-html", html: el.body }));
    },

    code(node, el) {
      const pre = h("pre", { class: el.lineNumbers ? "with-lines" : null });
      const code = h("code", { class: el.language ? "language-" + el.language : null });
      code.textContent = el.body;
      if (el.lineNumbers) {
        const n = String(el.body).split("\n").length;
        const gutter = h("span", { class: "line-gutter", "aria-hidden": "true", text: Array.from({ length: n }, (_, i) => i + 1).join("\n") });
        pre.appendChild(gutter);
      }
      pre.appendChild(code);
      const copy = h("button", { class: "copy-btn", text: "Copy" });
      copy.addEventListener("click", () => {
        try { navigator.clipboard.writeText(el.body); copy.textContent = "Copied"; setTimeout(() => (copy.textContent = "Copy"), 1200); } catch (e) {}
      });
      node.wrap.appendChild(h("div", { class: "code-block" }, pre, copy));
    },

    divider(node) { node.wrap.appendChild(h("hr", { class: "divider" })); },

    latex(node, el) {
      const d = h("div", { class: "latex", "data-testid": "st-latex", title: el.help || null },
        h("span", { class: "st-math", "data-display": "1", "data-tex": el.body, text: el.body }));
      node.wrap.appendChild(d);
    },

    map(node, el) {
      const div = h("div", { class: "map-wrap", "data-testid": "st-map", style: { height: (el.height || 400) + "px" } });
      node.wrap.appendChild(div);
      let map = null;
      loadLeaflet().then(() => {
        map = L.map(div, { attributionControl: true, scrollWheelZoom: false });
        L.tileLayer(el.tileUrl, { attribution: el.attribution, maxZoom: 19 }).addTo(map);
        const base = cssVarValue("--chart-1") || "#ff4b4b";
        const pts = el.points || [];
        const latlngs = [];
        for (const p of pts) {
          const color = p.color || el.color || base;
          const opts = { color, fillColor: color, fillOpacity: 0.6, weight: 1 };
          const r = p.size || el.radius;
          (r > 0 ? L.circle([p.lat, p.lon], Object.assign({ radius: r }, opts)) : L.circleMarker([p.lat, p.lon], Object.assign({ radius: 6 }, opts))).addTo(map);
          latlngs.push([p.lat, p.lon]);
        }
        const fit = () => {
          if (el.zoom >= 0 && latlngs.length) map.setView(latlngs[0], el.zoom);
          else if (latlngs.length > 1) map.fitBounds(latlngs, { padding: [20, 20], maxZoom: 15 });
          else if (latlngs.length === 1) map.setView(latlngs[0], 12);
          else map.setView([0, 0], 1);
        };
        fit();
        // maps created in hidden containers (tabs, expanders) have zero size: re-layout when shown
        let fitted = div.clientWidth > 0;
        node.resizeObs = new ResizeObserver(() => {
          if (!div.clientWidth) return;
          map.invalidateSize();
          if (!fitted) { fitted = true; fit(); }
        });
        node.resizeObs.observe(div);
        div.dataset.rendered = "1";
        div.dataset.points = String(latlngs.length);
      }).catch((err) => { div.textContent = "Map error: " + err; });
      node.destroy = () => { if (node.resizeObs) node.resizeObs.disconnect(); if (map) map.remove(); };
    },

    alert(node, el) {
      const icons = { success: "✅", info: "ℹ️", warning: "⚠️", error: "❌" };
      const d = h("div", { class: "alert alert-" + el.type, role: "alert", "data-testid": "st-alert-" + el.type });
      if (el.icon) d.appendChild(h("span", { class: "alert-icon", text: el.icon }));
      d.appendChild(mdEl(el.body));
      node.wrap.appendChild(d);
    },

    exception(node, el) {
      const d = h("div", { class: "exception", "data-testid": "st-exception" });
      d.appendChild(h("div", { class: "exc-title", text: (el.type || "Exception").split(".").pop() + ": " + el.message }));
      if (el.file) d.appendChild(h("div", { class: "exc-loc", text: el.file + ":" + el.line, style: { fontSize: ".8rem", opacity: .8 } }));
      if (el.trace) {
        const det = h("details", null, h("summary", { text: "Traceback" }), h("pre", { text: el.trace }));
        d.appendChild(det);
      }
      node.wrap.appendChild(d);
    },

    metric(node, el) {
      const d = h("div", { class: "metric" + (el.border ? " bordered" : ""), "data-testid": "st-metric" });
      const lab = h("div", { class: "metric-label", html: mdInline(el.label) });
      if (el.help) lab.appendChild(h("span", { class: "help", title: el.help, text: "?", style: { marginLeft: ".3rem" } }));
      d.appendChild(lab);
      d.appendChild(h("div", { class: "metric-value", text: el.value }));
      if (el.delta !== null && el.delta !== undefined && el.delta !== "") {
        const s = String(el.delta).trim();
        const neg = s.startsWith("-");
        let cls = neg ? "delta-down" : "delta-up";
        if (el.deltaColor === "inverse") cls = neg ? "delta-up" : "delta-down";
        if (el.deltaColor === "off") cls = "delta-off";
        d.appendChild(h("div", { class: "metric-delta " + cls, text: (neg ? "↓ " : "↑ ") + s.replace(/^[-+]/, "") }));
      }
      node.wrap.appendChild(d);
    },

    json(node, el) {
      const root = h("div", { class: "json-view", "data-testid": "st-json" });
      root.appendChild(jsonTree(el.value, null, el.expanded !== false, 0));
      node.wrap.appendChild(root);
    },

    progress(node, el) {
      const bar = h("div", { class: "progress-bar", style: { width: (el.value * 100).toFixed(1) + "%" } });
      const txt = h("div", { class: "progress-text", html: el.text ? mdInline(el.text) : "" });
      const d = h("div", { class: "progress-wrap", "data-testid": "st-progress", role: "progressbar", "aria-valuenow": Math.round(el.value * 100) }, el.text ? txt : null, h("div", { class: "progress-track" }, bar));
      node.wrap.appendChild(d);
      node.update = (e) => {
        bar.style.width = (e.value * 100).toFixed(1) + "%";
        txt.innerHTML = e.text ? mdInline(e.text) : "";
        d.setAttribute("aria-valuenow", Math.round(e.value * 100));
      };
    },

    spinner(node, el) {
      node.wrap.appendChild(h("div", { class: "spinner", "data-testid": "st-spinner" }, h("div", { class: "spinner-icon" }), h("span", { html: mdInline(el.text) })));
    },

    image(node, el) {
      const img = h("img", { src: el.src, alt: el.caption || "" });
      if (el.width > 0) img.style.width = el.width + "px";
      node.wrap.appendChild(h("div", { class: "image" + (el.fullWidth ? " full" : ""), "data-testid": "st-image" }, h("figure", null, img, el.caption ? h("figcaption", { html: mdInline(el.caption) }) : null)));
    },
    audio(node, el) { node.wrap.appendChild(h("audio", { controls: true, src: el.src, style: { width: "100%" } })); },
    video(node, el) { node.wrap.appendChild(h("video", { controls: true, src: el.src, style: { width: "100%" } })); },

    page_link(node, el) {
      const a = h("a", { class: "page-link", href: /^https?:/.test(el.urlPath || "") ? el.urlPath : BASE + (el.urlPath || "") }, el.icon ? h("span", { text: el.icon }) : null, h("span", { html: mdInline(el.label) }));
      a.addEventListener("click", (ev) => {
        if (/^https?:/.test(el.urlPath)) return;
        ev.preventDefault(); setPage(el.urlPath, true); sendRerun({});
      });
      node.wrap.appendChild(a);
    },

    // ------------------------------------------------------------ widgets
    button(node, el) {
      const box = widgetBox(node, el);
      const b = h("button", { class: btnClass(el), disabled: el.disabled || null, type: "button", title: el.help || null }, btnContent(el));
      b.addEventListener("click", () => triggerWidget(el));
      box.appendChild(b);
      node.update = () => {};
    },

    form_submit_button(node, el) {
      const box = widgetBox(node, el);
      const b = h("button", { class: btnClass(el), disabled: el.disabled || null, type: "button", title: el.help || null }, btnContent(el));
      if (S.forms[el.form]) S.forms[el.form].submitId = S.forms[el.form].submitId || el.id;
      b.addEventListener("click", () => {
        // commit focused input first
        if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
        submitForm(el.form, el.id);
      });
      box.appendChild(b);
      node.update = () => { if (S.forms[el.form]) S.forms[el.form].submitId = S.forms[el.form].submitId || el.id; };
    },

    download_button(node, el) {
      const box = widgetBox(node, el);
      const a = h("a", { class: btnClass(el), href: el.url, download: el.fileName || "", title: el.help || null, role: "button" }, btnContent(el));
      a.addEventListener("click", () => { setTimeout(() => triggerWidget(el), 50); });
      box.appendChild(a);
      node.update = () => {};
    },

    checkbox(node, el) { checkLike(node, el, false); },
    toggle(node, el) { checkLike(node, el, true); },

    radio(node, el) {
      const box = widgetBox(node, el);
      box.appendChild(labelEl(el));
      const g = h("div", { class: "radio-group" + (el.horizontal ? " horizontal" : ""), role: "radiogroup" });
      const name = nextId();
      const inputs = [];
      (el.options || []).forEach((o, i) => {
        const inp = h("input", { type: "radio", name, value: String(i), disabled: el.disabled || null });
        inp.checked = el.value === i;
        inp.addEventListener("change", () => { if (inp.checked) widgetChanged(el, i); });
        inputs.push(inp);
        g.appendChild(h("label", null, inp, h("span", { html: mdInline(o) })));
        if (el.captions && el.captions[i]) g.appendChild(h("div", { class: "radio-caption", html: mdInline(el.captions[i]) }));
      });
      box.appendChild(g);
      node.update = (e) => inputs.forEach((inp, i) => (inp.checked = e.value === i));
    },

    // themed, searchable select (assets/ui.js) instead of the browser's <select>
    selectbox(node, el) {
      const box = widgetBox(node, el);
      const id = nextId();
      box.appendChild(labelEl(el, id));
      const cb = StUI.combobox({
        id, options: (el.options || []).map((o) => ({ label: o })), value: el.value === undefined ? null : el.value,
        placeholder: el.placeholder || "Choose an option", disabled: el.disabled, onChange: (i) => widgetChanged(el, i),
      });
      box.appendChild(cb.el);
      node.update = (e) => { if (document.activeElement !== cb.input) cb.setValue(e.value === undefined ? null : e.value); };
    },

    multiselect(node, el) {
      const box = widgetBox(node, el);
      const id = nextId();
      box.appendChild(labelEl(el, id));
      const mc = StUI.multiCombobox({
        id, options: (el.options || []).map((o) => ({ label: o })), value: el.value || [], max: el.maxSelections,
        placeholder: el.placeholder || "Choose options", disabled: el.disabled, onChange: (v) => widgetChanged(el, v),
      });
      box.appendChild(mc.el);
      node.update = (e) => mc.setValue(e.value || []);
    },

    slider(node, el) {
      const box = widgetBox(node, el, "slider-wrap");
      box.appendChild(labelEl(el));
      const valRow = h("div", { class: "slider-value" });
      const track = h("div", { class: "slider-track" }, h("div", { class: "rail" }));
      const fill = h("div", { class: "fill" });
      track.appendChild(fill);
      const n = el.range ? 2 : 1;
      const inputs = [];
      const labels = [];
      let value = el.range ? (el.value || [el.min, el.max]).slice() : [el.value];
      for (let i = 0; i < n; i++) {
        const inp = h("input", { type: "range", min: el.min, max: el.max, step: el.step, disabled: el.disabled || null, "aria-label": el.label + (n > 1 ? (i ? " high" : " low") : "") });
        inp.value = value[i];
        inputs.push(inp);
        track.appendChild(inp);
        const lab = h("span");
        labels.push(lab);
        valRow.appendChild(lab);
      }
      const pct = (v) => (el.max === el.min ? 0 : ((v - el.min) / (el.max - el.min)) * 100);
      const draw = () => {
        for (let i = 0; i < n; i++) {
          labels[i].textContent = fmtNum(value[i], el);
          labels[i].style.left = pct(value[i]) + "%";
        }
        const a = n === 2 ? pct(Math.min(value[0], value[1])) : 0;
        const b = n === 2 ? pct(Math.max(value[0], value[1])) : pct(value[0]);
        fill.style.left = a + "%";
        fill.style.width = (b - a) + "%";
      };
      const read = () => inputs.map((inp) => (el.isInt ? parseInt(inp.value, 10) : parseFloat(inp.value)));
      inputs.forEach((inp) => {
        inp.addEventListener("input", () => { value = read(); draw(); });
        inp.addEventListener("change", () => {
          value = read();
          draw();
          const v = n === 2 ? [Math.min(value[0], value[1]), Math.max(value[0], value[1])] : value[0];
          widgetChanged(el, v);
        });
      });
      box.append(valRow, track, h("div", { class: "slider-minmax" }, h("span", { text: fmtNum(el.min, el) }), h("span", { text: fmtNum(el.max, el) })));
      draw();
      node.update = (e) => {
        if (inputs.includes(document.activeElement)) return;
        value = e.range ? e.value.slice() : [e.value];
        inputs.forEach((inp, i) => (inp.value = value[i]));
        draw();
      };
    },

    select_slider(node, el) {
      const box = widgetBox(node, el, "slider-wrap");
      box.appendChild(labelEl(el));
      const max = Math.max(0, (el.options || []).length - 1);
      const valRow = h("div", { class: "slider-value" });
      const lab = h("span");
      valRow.appendChild(lab);
      const track = h("div", { class: "slider-track" }, h("div", { class: "rail" }));
      const fill = h("div", { class: "fill" });
      const inp = h("input", { type: "range", min: 0, max, step: 1, disabled: el.disabled || null, "aria-label": el.label });
      inp.value = el.value;
      track.append(fill, inp);
      const draw = () => {
        const i = +inp.value;
        const p = max ? (i / max) * 100 : 0;
        lab.textContent = el.options[i];
        lab.style.left = p + "%";
        fill.style.left = "0"; fill.style.width = p + "%";
      };
      inp.addEventListener("input", draw);
      inp.addEventListener("change", () => { draw(); widgetChanged(el, +inp.value); });
      box.append(valRow, track, h("div", { class: "slider-minmax" }, h("span", { text: el.options[0] || "" }), h("span", { text: el.options[max] || "" })));
      draw();
      node.update = (e) => { if (document.activeElement !== inp) { inp.value = e.value; draw(); } };
    },

    text_input(node, el) {
      const box = widgetBox(node, el);
      const id = nextId();
      box.appendChild(labelEl(el, id));
      const inp = h("input", { class: "st-input", id, type: el.type === "password" ? "password" : "text", placeholder: el.placeholder || "", disabled: el.disabled || null, maxlength: el.maxChars > 0 ? el.maxChars : null, autocomplete: "off" });
      inp.value = el.value || "";
      let committed = inp.value;
      const commit = () => {
        if (inp.value === committed) return;
        committed = inp.value;
        widgetChanged(el, inp.value);
      };
      inp.addEventListener("blur", commit);
      inp.addEventListener("keydown", (ev) => {
        if (ev.key === "Enter") {
          ev.preventDefault();
          commit();
          if (el.form && S.forms[el.form] && S.forms[el.form].enterToSubmit) submitForm(el.form);
        }
      });
      const wrap = h("div", { class: "input-wrap" }, inp);
      if (el.maxChars > 0) {
        const hint = h("div", { class: "input-hint", text: inp.value.length + "/" + el.maxChars });
        inp.addEventListener("input", () => (hint.textContent = inp.value.length + "/" + el.maxChars));
        wrap.appendChild(hint);
      }
      box.appendChild(wrap);
      node.update = (e) => {
        if (document.activeElement === inp) return;
        inp.value = e.value || "";
        committed = inp.value;
      };
    },

    text_area(node, el) {
      const box = widgetBox(node, el);
      const id = nextId();
      box.appendChild(labelEl(el, id));
      const ta = h("textarea", { class: "st-textarea", id, placeholder: el.placeholder || "", disabled: el.disabled || null, maxlength: el.maxChars > 0 ? el.maxChars : null });
      if (el.height > 0) ta.style.height = el.height + "px";
      ta.value = el.value || "";
      let committed = ta.value;
      const commit = () => { if (ta.value !== committed) { committed = ta.value; widgetChanged(el, ta.value); } };
      ta.addEventListener("blur", commit);
      ta.addEventListener("keydown", (ev) => { if (ev.key === "Enter" && (ev.ctrlKey || ev.metaKey)) { ev.preventDefault(); commit(); } });
      box.appendChild(ta);
      node.update = (e) => { if (document.activeElement !== ta) { ta.value = e.value || ""; committed = ta.value; } };
    },

    number_input(node, el) {
      const box = widgetBox(node, el);
      const id = nextId();
      box.appendChild(labelEl(el, id));
      const inp = h("input", { id, type: "number", step: el.step, placeholder: el.placeholder || "", disabled: el.disabled || null });
      if (el.min !== null && el.min !== undefined) inp.min = el.min;
      if (el.max !== null && el.max !== undefined) inp.max = el.max;
      inp.value = fmtNum(el.value, el);
      let committed = el.value;
      const clamp = (v) => {
        if (el.min !== null && el.min !== undefined && v < el.min) v = el.min;
        if (el.max !== null && el.max !== undefined && v > el.max) v = el.max;
        return v;
      };
      const commit = (v) => {
        if (v === undefined) {
          if (inp.value === "") { inp.value = fmtNum(committed, el); return; }
          v = el.isInt ? parseInt(inp.value, 10) : parseFloat(inp.value);
          if (isNaN(v)) { inp.value = fmtNum(committed, el); return; }
        }
        v = clamp(v);
        inp.value = fmtNum(v, el);
        if (v === committed) return;
        committed = v;
        widgetChanged(el, v);
      };
      inp.addEventListener("blur", () => commit());
      inp.addEventListener("keydown", (ev) => {
        if (ev.key === "Enter") {
          ev.preventDefault(); commit();
          if (el.form && S.forms[el.form] && S.forms[el.form].enterToSubmit) submitForm(el.form);
        }
      });
      const round = (v) => (el.isInt ? Math.round(v) : Math.round(v / el.step) * el.step);
      const minus = h("button", { type: "button", text: "−", "aria-label": "Decrement", disabled: el.disabled || null });
      const plus = h("button", { type: "button", text: "+", "aria-label": "Increment", disabled: el.disabled || null });
      minus.addEventListener("click", () => commit(round((committed || 0) - el.step)));
      plus.addEventListener("click", () => commit(round((committed || 0) + el.step)));
      box.appendChild(h("div", { class: "number-wrap" }, inp, minus, plus));
      node.update = (e) => { if (document.activeElement !== inp) { committed = e.value; inp.value = fmtNum(e.value, el); } };
    },

    date_input(node, el) {
      const box = widgetBox(node, el);
      const id = nextId();
      box.appendChild(labelEl(el, id));
      const dp = StUI.datePicker({ id, value: el.value, min: el.min, max: el.max, disabled: el.disabled, onChange: (v) => widgetChanged(el, v) });
      box.appendChild(dp.el);
      node.update = (e) => dp.setValue(e.value);
    },

    time_input(node, el) {
      const box = widgetBox(node, el);
      const id = nextId();
      box.appendChild(labelEl(el, id));
      const tp = StUI.timePicker({ id, value: el.value, step: el.step, disabled: el.disabled, onChange: (v) => widgetChanged(el, v) });
      box.appendChild(tp.el);
      node.update = (e) => tp.setValue(e.value);
    },

    color_picker(node, el) {
      const box = widgetBox(node, el);
      const id = nextId();
      box.appendChild(labelEl(el, id));
      const swatches = () => {
        const v = (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
        return ["--primary", "--text", "--bg"].concat(Array.from({ length: 10 }, (_, i) => "--chart-" + (i + 1))).map(v);
      };
      const cp = StUI.colorPicker({ id, label: el.label, value: el.value, disabled: el.disabled, swatches, onChange: (v) => widgetChanged(el, v) });
      box.appendChild(cp.el);
      node.update = (e) => cp.setValue(e.value);
    },

    file_uploader(node, el) {
      const box = widgetBox(node, el);
      box.appendChild(labelEl(el));
      let files = (el.value || []).slice();
      const input = h("input", { type: "file", hidden: true, multiple: el.multiple || null, accept: (el.accept || []).map((a) => (a.startsWith(".") || a.includes("/") ? a : "." + a)).join(",") || null, "data-testid": "st-file-input" });
      const browse = h("button", { type: "button", class: "st-btn", text: "Browse files", disabled: el.disabled || null });
      const drop = h("div", { class: "uploader-drop" },
        h("div", { class: "hint", html: "<b>Drag and drop file" + (el.multiple ? "s" : "") + " here</b>" + (el.accept && el.accept.length ? esc(el.accept.map((a) => a.toUpperCase()).join(", ")) : "Limit 200MB per file") }),
        browse, input);
      const list = h("div", { class: "uploaded-files" });
      box.append(drop, list);
      const drawList = () => {
        list.innerHTML = "";
        files.forEach((f) => {
          const x = h("button", { type: "button", title: "Remove", text: "×", "aria-label": "Remove " + f.name });
          x.addEventListener("click", () => { files = files.filter((g) => g.fileId !== f.fileId); drawList(); widgetChanged(el, files.slice()); });
          list.appendChild(h("div", { class: "uploaded-file", "data-testid": "st-uploaded-file" }, h("span", { text: "\u{1F4C4}" }), h("span", { text: f.name }), h("span", { class: "fsize", text: fmtSize(f.size) }), x));
        });
      };
      const upload = async (fileList) => {
        const arr = Array.from(fileList);
        if (!arr.length) return;
        const uploaded = [];
        for (const f of el.multiple ? arr : arr.slice(0, 1)) {
          const url = "_upload/" + encodeURIComponent(S.sessionId || el.sessionId) + "/" + encodeURIComponent(el.id) + "?name=" + encodeURIComponent(f.name) + "&type=" + encodeURIComponent(f.type || "");
          const r = await fetch(url, { method: "POST", body: f });
          if (r.ok) uploaded.push(await r.json());
        }
        files = el.multiple ? files.concat(uploaded) : uploaded;
        drawList();
        widgetChanged(el, files.slice());
      };
      browse.addEventListener("click", () => input.click());
      input.addEventListener("change", () => { upload(input.files); input.value = ""; });
      drop.addEventListener("dragover", (ev) => { ev.preventDefault(); drop.classList.add("drag"); });
      drop.addEventListener("dragleave", () => drop.classList.remove("drag"));
      drop.addEventListener("drop", (ev) => { ev.preventDefault(); drop.classList.remove("drag"); upload(ev.dataTransfer.files); });
      drawList();
      node.update = (e) => { files = (e.value || []).slice(); drawList(); };
    },

    chat_input(node, el) {
      const box = h("div", { class: "chat-input" + (el.disabled ? " disabled" : ""), "data-testid": "st-chat-input" });
      const ta = h("textarea", { placeholder: el.placeholder || "", rows: 1, maxlength: el.maxChars > 0 ? el.maxChars : null, "aria-label": el.placeholder || "Chat input" });
      const btn = h("button", { type: "button", title: "Send", text: "➤", "aria-label": "Send" });
      const submit = () => {
        const v = ta.value.trim();
        if (!v) return;
        ta.value = "";
        ta.style.height = "";
        triggerWidget(el, v);
      };
      ta.addEventListener("keydown", (ev) => { if (ev.key === "Enter" && !ev.shiftKey) { ev.preventDefault(); submit(); } });
      ta.addEventListener("input", () => { ta.style.height = "auto"; ta.style.height = Math.min(ta.scrollHeight, 192) + "px"; });
      btn.addEventListener("click", submit);
      box.append(ta, btn);
      node.wrap.appendChild(box);
      node.update = () => {};
    },

    // ------------------------------------------------------------ data
    dataframe(node, el) { renderDataframe(node, el, false); },
    data_editor(node, el) { renderDataframe(node, el, true); },
    table(node, el) {
      const cols = el.columns || [];
      const t = h("table", { class: "static", "data-testid": "st-table" });
      const hr = h("tr");
      if (!el.hideIndex) hr.appendChild(h("th", { text: "" }));
      cols.forEach((c) => hr.appendChild(h("th", { class: isNumCol(c) ? "num" : null, text: c.name })));
      t.appendChild(h("thead", null, hr));
      const tb = h("tbody");
      (el.data || []).forEach((row, ri) => {
        const tr = h("tr");
        if (!el.hideIndex) tr.appendChild(h("th", { text: String(ri) }));
        row.forEach((v, ci) => tr.appendChild(h("td", { class: isNumCol(cols[ci]) ? "num" : null, text: fmtCell(v, cols[ci]) })));
        tb.appendChild(tr);
      });
      t.appendChild(tb);
      node.wrap.appendChild(h("div", { style: { overflowX: "auto" } }, t));
    },

    pills(node, el) { choiceGroup(node, el, "pills"); },
    segmented_control(node, el) { choiceGroup(node, el, "segmented"); },
    feedback(node, el) { choiceGroup(node, el, "feedback"); },

    link_button(node, el) {
      const a = h("a", { class: btnClass(el) + (el.disabled ? " disabled" : ""), href: el.url, target: "_blank", rel: "noopener noreferrer", title: el.help || null, "data-testid": "st-link-button" }, btnContent(el));
      node.wrap.appendChild(a);
    },

    badge(node, el) {
      node.wrap.appendChild(h("span", { class: "badge badge-" + (el.color || "blue"), "data-testid": "st-badge" }, el.icon ? h("span", { text: el.icon }) : null, h("span", { html: mdInline(el.label) })));
    },

    component_html(node, el) {
      const f = h("iframe", { class: "component-frame", sandbox: "allow-scripts allow-forms allow-popups allow-downloads", scrolling: el.scrolling ? "yes" : "no", title: "component", "data-testid": "st-component-html" });
      f.srcdoc = el.html;
      f.style.height = (el.height || 150) + "px";
      node.wrap.appendChild(f);
    },

    iframe(node, el) {
      const f = h("iframe", { class: "component-frame", src: el.src, scrolling: el.scrolling ? "yes" : "no", title: "iframe", "data-testid": "st-iframe" });
      f.style.height = (el.height || 150) + "px";
      if (el.width > 0) f.style.width = el.width + "px";
      node.wrap.appendChild(f);
    },

    // Bidirectional component (Streamlit component protocol over postMessage).
    component(node, el) {
      const f = h("iframe", { class: "component-frame", src: el.src, title: el.name, "data-testid": "st-component", "data-name": el.name,
        sandbox: "allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox allow-downloads" });
      f.style.height = (el.height > 0 ? el.height : 0) + "px";
      node.wrap.appendChild(f);
      let ready = false;
      let current = el;
      const render = () => {
        if (!ready || !f.contentWindow) return;
        f.contentWindow.postMessage({ type: "streamlit:render", args: current.args || {}, dfs: [], disabled: !!current.disabled, theme: componentTheme() }, "*");
      };
      const onMsg = (ev) => {
        if (ev.source !== f.contentWindow || !ev.data || !ev.data.isStreamlitMessage) return;
        const d = ev.data;
        if (d.type === "streamlit:componentReady") { ready = true; render(); }
        else if (d.type === "streamlit:setComponentValue") {
          if (d.dataType && d.dataType !== "json") return; // Arrow/bytes values are not supported
          widgetChanged(current, d.value === undefined ? null : d.value);
        } else if (d.type === "streamlit:setFrameHeight") {
          if (!(current.height > 0) && typeof d.height === "number") f.style.height = d.height + "px";
        }
      };
      window.addEventListener("message", onMsg);
      node.update = (e) => { const argsChanged = JSON.stringify(e.args) !== JSON.stringify(current.args); current = e; if (argsChanged) render(); };
      node.rerenderTheme = render;
      node.destroy = () => window.removeEventListener("message", onMsg);
    },

    plotly(node, el) {
      const div = h("div", { class: "plotly-wrap", "data-testid": "st-plotly" });
      node.wrap.appendChild(div);
      let lastFig = null;
      const draw = (e) => {
        const figStr = JSON.stringify([e.figure, e.theme, e.height, T.lastKey]);
        if (figStr === lastFig) return;
        lastFig = figStr;
        loadPlotly().then(() => {
          const fig = JSON.parse(JSON.stringify(e.figure));
          const layout = Object.assign({}, fig.layout || {});
          if (e.theme === "streamlit") {
            applyPlotlyTheme(layout);
            // the design's line weight for line traces that don't set their own
            const sw = T.design && T.design.chart && T.design.chart.strokeWidth;
            if (sw) for (const tr of fig.data || []) {
              const lines = (tr.type === undefined || tr.type === "scatter" || tr.type === "scattergl") && (tr.mode === undefined || String(tr.mode).includes("lines"));
              if (lines && !(tr.line && tr.line.width !== undefined)) tr.line = Object.assign({}, tr.line, { width: sw });
            }
          }
          if (e.height > 0) layout.height = e.height;
          else if (!layout.height) layout.height = 400;
          layout.autosize = true;
          const config = Object.assign({ responsive: true, displaylogo: false }, fig.config || {});
          return Plotly.react(div, fig.data || [], layout, config);
        }).then(() => {
          div.dataset.rendered = "1";
          if (!node.resizeObs) {
            let w = div.clientWidth;
            node.resizeObs = new ResizeObserver(() => {
              if (div.clientWidth && div.clientWidth !== w) { w = div.clientWidth; try { Plotly.Plots.resize(div); } catch (err) {} }
            });
            node.resizeObs.observe(div);
          }
          if (e.selectable && !div.dataset.bound) {
            div.dataset.bound = "1";
            div.on("plotly_selected", (ev) => {
              const pts = ev && ev.points ? ev.points.map((p) => ({ curveNumber: p.curveNumber, pointIndex: p.pointIndex, x: p.x, y: p.y })) : [];
              widgetChanged(node.el, { points: pts });
            });
            div.on("plotly_click", (ev) => {
              const pts = ev && ev.points ? ev.points.map((p) => ({ curveNumber: p.curveNumber, pointIndex: p.pointIndex, x: p.x, y: p.y })) : [];
              widgetChanged(node.el, { points: pts });
            });
            div.on("plotly_deselect", () => widgetChanged(node.el, null));
          }
        }).catch((err) => { div.textContent = "Chart error: " + err; });
      };
      draw(el);
      node.update = draw;
      node.destroy = () => { if (node.resizeObs) node.resizeObs.disconnect(); try { if (window.Plotly) Plotly.purge(div); } catch (e) {} };
    },

    vega_lite(node, el) {
      const div = h("div", { class: "vega-wrap", "data-testid": "st-vega-lite" });
      node.wrap.appendChild(div);
      let view = null;
      let lastSpec = null;
      const draw = (e) => {
        const specStr = JSON.stringify(e.spec);
        if (specStr === lastSpec) return;
        lastSpec = specStr;
        loadVega().then(() => {
          const spec = JSON.parse(specStr);
          spec.config = Object.assign({}, vegaTheme(), spec.config || {});
          if (spec.background === undefined) spec.background = "transparent";
          return vegaEmbed(div, spec, { actions: { export: true, source: false, compiled: false, editor: false }, renderer: "svg" });
        }).then((res) => {
          if (view) try { view.finalize(); } catch (e) {}
          view = res ? res.view : null;
          if (!node.resizeObs) {
            let w = div.clientWidth;
            node.resizeObs = new ResizeObserver(() => {
              if (div.clientWidth && div.clientWidth !== w && view) { w = div.clientWidth; try { view.resize().runAsync(); } catch (err) {} }
            });
            node.resizeObs.observe(div);
          }
          div.dataset.rendered = "1";
        }).catch((err) => { div.textContent = "Chart error: " + err; });
      };
      draw(el);
      node.update = draw;
      node.destroy = () => { if (node.resizeObs) node.resizeObs.disconnect(); if (view) try { view.finalize(); } catch (e) {} };
    },
  };

  // pills / segmented control / feedback: a row of toggle buttons (single or multi selection)
  function choiceGroup(node, el, style) {
    const box = widgetBox(node, el);
    if (el.label) box.appendChild(labelEl(el));
    const row = h("div", { class: "choice-group " + style + (el.feedbackType ? " fb-" + el.feedbackType : ""), role: el.multi ? "group" : "radiogroup", "aria-label": el.label || el.feedbackType || "" });
    box.appendChild(row);
    let value = el.multi ? (el.value || []).slice() : el.value;
    const btns = (el.options || []).map((o, i) => {
      const b = h("button", { type: "button", class: "choice", disabled: el.disabled || null, "data-index": String(i), "aria-label": el.feedbackType ? el.feedbackType + " " + (i + 1) : o, text: o });
      b.addEventListener("click", () => {
        if (el.multi) {
          value = value.includes(i) ? value.filter((v) => v !== i) : value.concat([i]).sort((a, b) => a - b);
          draw();
          widgetChanged(el, value.slice());
        } else {
          value = value === i ? null : i;
          draw();
          widgetChanged(el, value);
        }
      });
      row.appendChild(b);
      return b;
    });
    const draw = () => btns.forEach((b, i) => {
      let on = el.multi ? value.includes(i) : value === i;
      if (el.feedbackType === "stars") on = value !== null && value !== undefined && i <= value;
      b.classList.toggle("active", on);
      b.setAttribute("aria-pressed", on ? "true" : "false");
    });
    draw();
    node.update = (e) => { value = e.multi ? (e.value || []).slice() : e.value; draw(); };
  }

  function checkLike(node, el, isToggle) {
    const box = widgetBox(node, el);
    const inp = h("input", { type: "checkbox", class: isToggle ? "toggle-input" : null, disabled: el.disabled || null, role: isToggle ? "switch" : null });
    inp.checked = !!el.value;
    inp.addEventListener("change", () => widgetChanged(el, inp.checked));
    const vis = el.labelVisibility || "visible";
    const text = h("span", { html: mdInline(el.label), style: vis !== "visible" ? { display: "none" } : null });
    const lab = h("label", { class: "check" }, inp, isToggle ? h("span", { class: "toggle-switch" }) : null, text);
    if (el.help) lab.appendChild(h("span", { class: "help", title: el.help, text: "?" }));
    box.appendChild(lab);
    node.update = (e) => { inp.checked = !!e.value; };
  }

  function fmtSize(n) {
    if (n < 1024) return n + " B";
    if (n < 1048576) return (n / 1024).toFixed(1) + " KB";
    return (n / 1048576).toFixed(1) + " MB";
  }

  // ------------------------------------------------------------------ json tree
  function jsonTree(v, key, open, depth) {
    const keyEl = key !== null ? [h("span", { class: "k", text: JSON.stringify(key) }), ": "] : [];
    if (v !== null && typeof v === "object") {
      const isArr = Array.isArray(v);
      const entries = isArr ? v.map((x, i) => [i, x]) : Object.entries(v);
      const det = h("details", { open: open || null });
      det.appendChild(h("summary", null, ...keyEl, isArr ? "[" : "{", h("span", { class: "z", text: " " + entries.length + (isArr ? " items" : " keys") + " " }), entries.length ? "" : (isArr ? "]" : "}")));
      for (const [k, x] of entries) det.appendChild(jsonTree(x, isArr ? null : k, open && depth < 3, depth + 1));
      det.appendChild(h("div", { text: isArr ? "]" : "}" }));
      return det;
    }
    const cls = typeof v === "string" ? "s" : typeof v === "number" ? "n" : typeof v === "boolean" ? "b" : "z";
    return h("div", { class: "jv-row" }, ...keyEl, h("span", { class: cls, text: JSON.stringify(v) }));
  }

  // ------------------------------------------------------------------ dataframe
  function isNumCol(c) { return c && (c.type === "integer" || c.type === "number"); }
  function fmtCell(v, col) {
    if (v === null || v === undefined) return "None";
    if (typeof v === "number") {
      if (col && col.type === "number" && !Number.isInteger(v)) {
        const a = Math.abs(v);
        return a !== 0 && (a < 1e-4 || a >= 1e15) ? v.toExponential(4) : String(+v.toFixed(4));
      }
      return String(v);
    }
    if (typeof v === "boolean") return v ? "true" : "false";
    if (typeof v === "object") return JSON.stringify(v);
    return String(v);
  }
  function cmpCells(a, b) {
    const an = a === null || a === undefined, bn = b === null || b === undefined;
    if (an || bn) return an === bn ? 0 : an ? 1 : -1;
    if (typeof a === "number" && typeof b === "number") return a - b;
    return String(a).localeCompare(String(b));
  }

  function renderDataframe(node, el, editable) {
    const cols = el.columns || [];
    const data = el.data || [];
    const container = h("div", { class: "df-container", "data-testid": editable ? "st-data-editor" : "st-dataframe" });
    const toolbar = h("div", { class: "df-toolbar" });
    const wrap = h("div", { class: "df-wrap" });
    if (el.height > 0) wrap.style.maxHeight = el.height + "px";
    container.append(toolbar, wrap);
    node.wrap.appendChild(container);

    let sortCol = -1, sortDir = 1, filter = "";
    const state = editable ? JSON.parse(JSON.stringify(el.value || {})) : null;
    if (state) { state.edited = state.edited || {}; state.added = state.added || []; state.deleted = state.deleted || []; }
    const selected = new Set();
    const disabledCols = new Set(el.disabledCols || []);

    if (!editable) {
      const search = h("input", { type: "search", placeholder: "Search", "aria-label": "Search table" });
      search.addEventListener("input", () => { filter = search.value.toLowerCase(); draw(); });
      const dl = h("button", { type: "button", text: "⬇ CSV", title: "Download as CSV" });
      dl.addEventListener("click", () => downloadCsv(cols, data));
      toolbar.append(search, dl);
    }

    const commit = () => widgetChanged(el, JSON.parse(JSON.stringify(state)));
    const setCell = (ri, col, v) => {
      const src = el.rowMap[ri];
      if (src >= 0) {
        state.edited[src] = state.edited[src] || {};
        state.edited[src][col.name] = v;
      } else {
        const k = -src - 1;
        state.added[k] = state.added[k] || {};
        state.added[k][col.name] = v;
      }
      commit();
    };

    const draw = () => {
      let rows = data.map((r, i) => i);
      if (filter) rows = rows.filter((i) => data[i].some((v) => fmtCell(v).toLowerCase().includes(filter)));
      if (sortCol >= 0) rows.sort((a, b) => sortDir * cmpCells(data[a][sortCol], data[b][sortCol]));
      const t = h("table", { class: "df" });
      const hr = h("tr");
      if (editable && el.numRows === "dynamic") hr.appendChild(h("th", { class: "rowsel idx", text: "" }));
      if (!el.hideIndex) hr.appendChild(h("th", { class: "idx", text: "" }));
      cols.forEach((c, ci) => {
        const th = h("th", { class: (isNumCol(c) ? "num " : "") + (ci === sortCol ? (sortDir > 0 ? "sorted-asc" : "sorted-desc") : ""), text: c.name, title: c.name + " (" + c.type + ")" });
        th.addEventListener("click", () => {
          if (sortCol === ci) { if (sortDir > 0) sortDir = -1; else { sortCol = -1; sortDir = 1; } }
          else { sortCol = ci; sortDir = 1; }
          draw();
        });
        hr.appendChild(th);
      });
      t.appendChild(h("thead", null, hr));
      const tb = h("tbody");
      for (const ri of rows) {
        const row = data[ri];
        const tr = h("tr", { class: editable && el.rowMap && el.rowMap[ri] < 0 ? "added" : null });
        if (editable && el.numRows === "dynamic") {
          const cb = h("input", { type: "checkbox", "aria-label": "Select row " + ri });
          cb.checked = selected.has(ri);
          cb.addEventListener("change", () => { if (cb.checked) selected.add(ri); else selected.delete(ri); delBtn.disabled = selected.size === 0; });
          tr.appendChild(h("td", { class: "rowsel idx" }, cb));
        }
        if (!el.hideIndex) tr.appendChild(h("td", { class: "idx", text: String(ri) }));
        row.forEach((v, ci) => {
          const col = cols[ci];
          if (editable && !el.disabled && !disabledCols.has(col.name)) {
            const td = h("td", { class: "edit" + (isNumCol(col) ? " num" : "") });
            let inp;
            if (col.type === "boolean") {
              inp = h("input", { type: "checkbox" });
              inp.checked = !!v;
              inp.addEventListener("change", () => setCell(ri, col, inp.checked));
            } else {
              inp = h("input", { type: isNumCol(col) ? "number" : col.type === "date" ? "date" : "text", step: col.type === "number" ? "any" : null });
              inp.value = v === null || v === undefined ? "" : (typeof v === "object" ? JSON.stringify(v) : String(v));
              const orig = inp.value;
              inp.addEventListener("change", () => {
                if (inp.value === orig) return;
                let nv = inp.value;
                if (isNumCol(col)) nv = nv === "" ? null : Number(nv);
                setCell(ri, col, nv);
              });
              inp.addEventListener("keydown", (ev) => { if (ev.key === "Enter") inp.blur(); });
            }
            inp.setAttribute("aria-label", col.name + " row " + ri);
            td.appendChild(inp);
            tr.appendChild(td);
          } else {
            tr.appendChild(h("td", { class: (isNumCol(col) ? "num" : "") + (v === null || v === undefined ? " null" : ""), text: fmtCell(v, col), title: fmtCell(v, col) }));
          }
        });
        tb.appendChild(tr);
      }
      t.appendChild(tb);
      wrap.innerHTML = "";
      wrap.appendChild(t);
    };

    let delBtn = null;
    if (editable && el.numRows === "dynamic" && !el.disabled) {
      const add = h("button", { type: "button", class: "st-btn", text: "+ Add row" });
      delBtn = h("button", { type: "button", class: "st-btn", text: "Delete selected", disabled: true });
      add.addEventListener("click", () => { state.added.push({}); commit(); });
      delBtn.addEventListener("click", () => {
        const addedIdx = [];
        selected.forEach((ri) => {
          const src = el.rowMap[ri];
          if (src >= 0) state.deleted.push(src); else addedIdx.push(-src - 1);
        });
        addedIdx.sort((a, b) => b - a).forEach((k) => state.added.splice(k, 1));
        selected.clear();
        commit();
      });
      container.appendChild(h("div", { class: "editor-actions" }, add, delBtn));
    }
    draw();
  }

  function downloadCsv(cols, data) {
    const q = (s) => (/[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s);
    const lines = [cols.map((c) => q(c.name)).join(",")];
    data.forEach((r) => lines.push(r.map((v) => q(v === null || v === undefined ? "" : typeof v === "object" ? JSON.stringify(v) : String(v))).join(",")));
    const blob = new Blob([lines.join("\n") + "\n"], { type: "text/csv" });
    const a = h("a", { href: URL.createObjectURL(blob), download: "data.csv" });
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  }

  // ------------------------------------------------------------------ vega
  function loadScript(src) {
    return new Promise((res, rej) => {
      const s = document.createElement("script");
      s.src = src; s.onload = res; s.onerror = () => rej(new Error("failed to load " + src));
      document.head.appendChild(s);
    });
  }
  function componentTheme() {
    const v = (n) => cssVarValue(n);
    return { base: isDark() ? "dark" : "light", primaryColor: v("--primary"), backgroundColor: v("--bg"),
      secondaryBackgroundColor: v("--bg2"), textColor: v("--text"), font: v("--font"),
      design: document.documentElement.dataset.design || "streamlit", colorScheme: document.documentElement.dataset.scheme || "streamlit" };
  }
  function loadCss(href) {
    return new Promise((res) => {
      const l = document.createElement("link");
      l.rel = "stylesheet"; l.href = href; l.onload = res; l.onerror = res;
      document.head.appendChild(l);
    });
  }
  function cssVarValue(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }
  function loadKatex() {
    if (!S.katexPromise) S.katexPromise = Promise.all([loadCss("static/vendor/katex/katex.min.css"), loadScript("static/vendor/katex/katex.min.js")]);
    return S.katexPromise;
  }
  function loadHljs() {
    if (!S.hljsPromise) S.hljsPromise = loadScript("static/vendor/hljs/highlight.min.js").then(() => loadScript("static/vendor/hljs/d.min.js"));
    return S.hljsPromise;
  }
  function loadLeaflet() {
    if (!S.leafletPromise) S.leafletPromise = Promise.all([loadCss("static/vendor/leaflet/leaflet.css"), loadScript("static/vendor/leaflet/leaflet.js")]);
    return S.leafletPromise;
  }
  // Render math (KaTeX) and highlight code blocks inside a freshly rendered element.
  function typeset(root) {
    const maths = root.querySelectorAll(".st-math:not([data-done])");
    if (maths.length) {
      loadKatex().then(() => maths.forEach((m) => {
        try { katex.render(m.dataset.tex, m, { displayMode: m.dataset.display === "1", throwOnError: false }); } catch (e) {}
        m.dataset.done = "1";
      }));
    }
    const codes = root.querySelectorAll("pre code[class*='language-']:not([data-hl])");
    if (codes.length) {
      loadHljs().then(() => codes.forEach((c) => {
        const lang = (c.className.match(/language-([\w+#-]+)/) || [])[1];
        c.dataset.hl = "1";
        if (!lang || !hljs.getLanguage(lang)) return;
        try { c.innerHTML = hljs.highlight(c.textContent, { language: lang, ignoreIllegals: true }).value; c.classList.add("hljs"); } catch (e) {}
      }));
    }
  }
  function loadPlotly() {
    if (!S.plotlyPromise) S.plotlyPromise = loadScript("static/vendor/plotly.min.js");
    return S.plotlyPromise;
  }
  // Merge the active design style into a Plotly layout (only keys the figure did not set).
  function applyPlotlyTheme(layout) {
    const dark = isDark();
    const text = T.textColor || (dark ? "#fafafa" : "#31333f");
    const grid = hexA(text, dark ? 0.12 : 0.1);
    const colors = T.chartColors && T.chartColors.length ? T.chartColors : ["#0068c9", "#83c9ff", "#ff2b2b", "#ffabab", "#29b09d", "#7defa1", "#ff8700", "#ffd16a", "#6d3fc0", "#d5dae5"];
    const setDefault = (o, k, v) => { if (o[k] === undefined) o[k] = v; };
    setDefault(layout, "paper_bgcolor", "rgba(0,0,0,0)");
    setDefault(layout, "plot_bgcolor", "rgba(0,0,0,0)");
    setDefault(layout, "colorway", colors);
    layout.font = Object.assign({ family: T.font || getComputedStyle(document.body).fontFamily, color: text }, layout.font || {});
    setDefault(layout, "margin", { l: 50, r: 20, t: layout.title ? 50 : 20, b: 40 });
    for (const ax of ["xaxis", "yaxis"]) {
      layout[ax] = Object.assign({ gridcolor: grid, zerolinecolor: grid, linecolor: grid }, layout[ax] || {});
    }
    layout.legend = Object.assign({ orientation: "h", y: -0.15 }, layout.legend || {});
    const c = (T.design && T.design.chart) || {};
    if (c.gridDash && c.gridDash.length) for (const ax of ["xaxis", "yaxis"]) if (layout[ax].griddash === undefined) layout[ax].griddash = "dot";
    if (c.barRadius && layout.barcornerradius === undefined) layout.barcornerradius = c.barRadius;
  }
  function loadVega() {
    if (!S.vegaPromise) {
      S.vegaPromise = loadScript("static/vendor/vega.min.js")
        .then(() => loadScript("static/vendor/vega-lite.min.js"))
        .then(() => loadScript("static/vendor/vega-embed.min.js"));
    }
    return S.vegaPromise;
  }
  function isDark() {
    const t = document.documentElement.dataset.theme;
    if (t) return t === "dark";
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  }
  function vegaTheme() {
    const dark = isDark();
    const text = T.textColor || (dark ? "#fafafa" : "#31333f");
    const grid = hexA(text, dark ? 0.12 : 0.1);
    const colors = T.chartColors && T.chartColors.length ? T.chartColors
      : ["#0068c9", "#83c9ff", "#ff2b2b", "#ffabab", "#29b09d", "#7defa1", "#ff8700", "#ffd16a", "#6d3fc0", "#d5dae5"];
    const c = (T.design && T.design.chart) || {};
    const sw = c.strokeWidth || 2;
    return {
      font: T.font || getComputedStyle(document.body).fontFamily,
      range: { category: colors },
      axis: { labelColor: text, titleColor: text, gridColor: grid, domainColor: grid, tickColor: grid, labelFontSize: 12, titleFontSize: 12, titleFontWeight: "normal",
        gridDash: c.gridDash || [] },
      legend: { labelColor: text, titleColor: text, labelFontSize: 12, titleFontSize: 12, orient: "bottom" },
      title: { color: text },
      view: { stroke: null },
      mark: { color: colors[0] },
      line: { strokeWidth: sw },
      area: { line: { strokeWidth: sw } },
      bar: { binSpacing: 1, cornerRadiusEnd: c.barRadius || 0 },
      arc: { stroke: null },
    };
  }

  // ------------------------------------------------------------------ themes: design × color scheme × mode
  // T.presets = color schemes (palettes), T.designs = design styles (UI shape).
  const T = { presets: [], designs: [], server: null, app: null, viewer: null, lastKey: null, design: null };
  try { T.viewer = JSON.parse(localStorage.getItem("streamlitd-appearance") || "null"); } catch (e) {}
  function saveViewer() {
    try {
      if (T.viewer) localStorage.setItem("streamlitd-appearance", JSON.stringify(T.viewer));
      else localStorage.removeItem("streamlitd-appearance");
    } catch (e) {}
  }
  // ---- accessible color derivation (WCAG contrast) ----
  const hexRgb = (hex) => { const m = /^#?([0-9a-f]{6})$/i.exec(hex || ""); if (!m) return null; const n = parseInt(m[1], 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; };
  const rgbHex = (c) => "#" + c.map((v) => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, "0")).join("");
  const relLum = (c) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }; return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]); };
  const contrast = (a, b) => { const l1 = relLum(a), l2 = relLum(b); return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05); };
  const mixRgb = (a, b, w) => a.map((v, i) => v * w + b[i] * (1 - w)); // w = weight of a
  /** Move `fg` toward `toward` until it reaches `target` contrast against every background. */
  function ensureContrast(fgHex, bgHexes, target, towardHex) {
    const fg = hexRgb(fgHex), bgs = bgHexes.map(hexRgb).filter(Boolean), to = hexRgb(towardHex);
    if (!fg || !bgs.length || !to) return fgHex;
    for (let w = 1; w >= 0; w -= 0.04) {
      const c = mixRgb(fg, to, w);
      if (bgs.every((b) => contrast(c, b) >= target)) return rgbHex(c);
    }
    return towardHex;
  }
  /** Lightest mix of `text` into `bg` that still reaches `target` on all backgrounds (muted text). */
  function mutedColor(textHex, bgHex, bgHexes, target) {
    const t = hexRgb(textHex), b = hexRgb(bgHex), bgs = bgHexes.map(hexRgb).filter(Boolean);
    if (!t || !b) return textHex && hexA(textHex, 0.6);
    for (let w = 0.6; w <= 1.0001; w += 0.04) {
      const c = mixRgb(t, b, w);
      if (bgs.every((x) => contrast(c, x) >= target)) return rgbHex(c);
    }
    return textHex;
  }

  function hexA(hex, a) {
    const m = /^#?([0-9a-f]{6})$/i.exec(hex || "");
    if (!m) return hex;
    const n = parseInt(m[1], 16);
    return "rgba(" + ((n >> 16) & 255) + ", " + ((n >> 8) & 255) + ", " + (n & 255) + ", " + a + ")";
  }
  const darkMq = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;
  function resolveMode(mode) { return mode === "auto" ? (darkMq && darkMq.matches ? "dark" : "light") : mode; }
  // messages from older servers used `preset` for the color scheme
  const schemeOf = (o) => (o && (o.scheme || o.preset)) || "streamlit";
  function baseTheme() { return T.app || T.server || { scheme: "streamlit", design: "streamlit", mode: "auto", overrides: {}, allowSwitch: true }; }
  function baseKey(b) { return schemeOf(b) + "/" + (b.design || "streamlit") + "/" + (b.mode || "auto"); }
  // The viewer's choice applies while the app keeps the theme it had when the choice was made;
  // an explicit change by the app (st.setTheme to something else) wins.
  function effectiveTheme() {
    const b = baseTheme();
    const allow = b.allowSwitch !== false;
    let scheme = schemeOf(b), design = b.design || "streamlit", mode = b.mode || "auto";
    const v = T.viewer;
    if (allow && v && v.basis === baseKey(b)) {
      if (v.scheme || v.preset) scheme = v.scheme || v.preset;
      if (v.design) design = v.design;
      if (v.mode) mode = v.mode;
    }
    return { scheme, design, mode, overrides: b.overrides || {}, allow };
  }
  function applyTheme() {
    if (!T.presets.length) return;
    const eff = effectiveTheme();
    const p = T.presets.find((x) => x.name === eff.scheme) || T.presets[0];
    const d = T.designs.find((x) => x.name === eff.design) || T.designs[0] || { name: "streamlit", tokens: {}, chart: {} };
    const dark = resolveMode(eff.mode) === "dark";
    const key = JSON.stringify([p.name, d.name, dark, eff.overrides]);
    T.current = eff;
    renderSettings();
    if (key === T.lastKey) return;
    T.lastKey = key;
    // precedence: scheme tokens < design-forced tokens (fonts, radius) < explicit overrides
    const t = Object.assign({}, dark ? p.dark : p.light, d.tokens || {}, eff.overrides);
    const root = document.documentElement;
    const set = (k, v) => { if (v !== undefined && v !== null && v !== "") root.style.setProperty(k, v); else root.style.removeProperty(k); };
    root.dataset.theme = dark ? "dark" : "light";
    root.dataset.style = p.name;   // color scheme (kept for compatibility)
    root.dataset.scheme = p.name;
    root.dataset.design = d.name;
    // Accessible derivations: --primary stays the brand color for borders/decoration (3:1 is enough);
    // fills that carry text use --primary-strong, primary-colored text uses --primary-ink, and body /
    // muted text are adjusted to reach 4.5:1 on every surface they appear on.
    const base = [t.backgroundColor, t.secondaryBackgroundColor, t.sidebarBackgroundColor, t.widgetBackgroundColor, t.codeBackgroundColor].filter(Boolean);
    // designs draw tonal surfaces (selected chips, material buttons/cards, hover rows) by tinting
    // these with the primary color: include such tints so text stays readable on them too
    const pr = hexRgb(t.primaryColor);
    const surfaces = base.concat(pr ? base.map((b) => { const c = hexRgb(b); return c ? rgbHex(mixRgb(pr, c, 0.2)) : null; }).filter(Boolean) : []);
    const ink = dark ? "#ffffff" : "#000000";
    const text = ensureContrast(t.textColor, surfaces, 4.5, ink);
    const onPrimary = t.primaryTextColor || "#ffffff";
    const onRgb = hexRgb(onPrimary);
    const strong = ensureContrast(t.primaryColor, [onPrimary], 4.5, onRgb && relLum(onRgb) > 0.5 ? "#000000" : "#ffffff");
    const primaryInk = ensureContrast(t.primaryColor, surfaces, 4.5, ink);
    set("--primary", t.primaryColor);
    set("--primary-strong", strong);
    set("--primary-ink", primaryInk);
    set("--primary-hover", strong && "color-mix(in srgb, " + strong + " 85%, " + (dark ? "white" : "black") + ")");
    set("--on-primary", onPrimary);
    set("--bg", t.backgroundColor);
    set("--bg2", t.secondaryBackgroundColor);
    set("--text", text);
    set("--text-muted", text && mutedColor(text, t.backgroundColor, surfaces, 4.5));
    set("--border", t.borderColor || (t.textColor && hexA(t.textColor, 0.2)));
    set("--border-light", t.textColor && hexA(t.textColor, 0.1));
    set("--link", ensureContrast(t.linkColor || t.primaryColor, surfaces, 4.5, ink));
    set("--sidebar-bg", t.sidebarBackgroundColor || t.secondaryBackgroundColor);
    set("--widget-bg", t.widgetBackgroundColor || t.secondaryBackgroundColor);
    set("--widget-border", t.widgetBorderColor || "transparent");
    set("--code-bg", t.codeBackgroundColor || t.secondaryBackgroundColor);
    set("--font", t.font);
    set("--heading-font", t.headingFont || t.font);
    set("--mono", t.codeFont);
    set("--radius", t.baseRadius);
    (t.chartColors || []).forEach((c, i) => set("--chart-" + (i + 1), c));
    T.chartColors = t.chartColors;
    T.textColor = t.textColor;
    T.font = t.font;
    T.design = d;
    rerenderCharts();
  }
  function rerenderCharts() {
    for (const k in S.roots) forEachNode(S.roots[k], (n) => {
      if (n.el && (n.el.kind === "vega_lite" || n.el.kind === "plotly")) { const el = n.el; n.el = { kind: "x" }; renderInto(n, el); }
      else if (n.rerenderTheme) n.rerenderTheme();
    });
  }
  function setViewer(change) {
    const eff = effectiveTheme();
    T.viewer = Object.assign({ scheme: eff.scheme, design: eff.design, mode: eff.mode }, change, { basis: baseKey(baseTheme()) });
    delete T.viewer.preset;
    saveViewer();
    applyTheme();
  }
  function renderSettings() {
    const eff = T.current || effectiveTheme();
    $("#stSettingsWrap").hidden = !eff.allow;
    document.querySelectorAll("#stModeSeg button").forEach((b) => {
      b.classList.toggle("active", b.dataset.mode === eff.mode);
      b.setAttribute("aria-pressed", b.dataset.mode === eff.mode ? "true" : "false");
    });
    // design styles (themed combobox, no native <select>)
    if (!T.designCb || T.designCb.n !== T.designs.length) {
      T.designCb = StUI.combobox({ id: "stDesignSelect", label: "Design style", testid: "st-design-select",
        options: T.designs.map((d) => ({ label: d.label, hint: d.description })),
        value: 0, onChange: (i) => setViewer({ design: T.designs[i].name }) });
      T.designCb.n = T.designs.length;
      $("#stDesignMount").replaceChildren(T.designCb.el);
      const cards = $("#stDesignCards");
      cards.innerHTML = "";
      T.designs.forEach((d) => {
        // a mini preview: the card itself is rendered in that design (scoped data-design)
        const b = h("button", { type: "button", class: "design-card", "data-design-card": d.name, title: d.description },
          h("span", { class: "dc-preview", "data-design": d.name },
            h("span", { class: "dc-bar" }), h("span", { class: "dc-btn", text: "Ok" }), h("span", { class: "dc-input" })),
          h("span", { class: "dc-label", text: d.label }));
        b.addEventListener("click", () => setViewer({ design: d.name }));
        cards.appendChild(b);
      });
    }
    T.designCb.setValue(Math.max(0, T.designs.findIndex((d) => d.name === eff.design)));
    document.querySelectorAll(".design-card").forEach((b) => b.classList.toggle("active", b.dataset.designCard === eff.design));
    // color schemes
    if (!T.schemeCb || T.schemeCb.n !== T.presets.length) {
      T.schemeCb = StUI.combobox({ id: "stStyleSelect", label: "Color scheme", testid: "st-scheme-select",
        options: T.presets.map((p) => ({ label: p.label, swatches: [p.light.backgroundColor, p.light.primaryColor, p.light.chartColors[0], p.dark.backgroundColor] })),
        value: 0, onChange: (i) => setViewer({ scheme: T.presets[i].name }) });
      T.schemeCb.n = T.presets.length;
      $("#stSchemeMount").replaceChildren(T.schemeCb.el);
      const sw = $("#stSwatches");
      sw.innerHTML = "";
      T.presets.forEach((p) => {
        const dots = h("span", { class: "dots" }, [p.light.backgroundColor, p.light.primaryColor, p.light.chartColors[0], p.dark.backgroundColor]
          .map((c) => h("span", { style: { background: c } })));
        const b = h("button", { type: "button", class: "style-swatch", "data-style": p.name, title: p.label, style: { fontFamily: p.light.font } }, dots, h("span", { text: p.label }));
        b.addEventListener("click", () => setViewer({ scheme: p.name }));
        sw.appendChild(b);
      });
    }
    T.schemeCb.setValue(Math.max(0, T.presets.findIndex((p) => p.name === eff.scheme)));
    document.querySelectorAll(".style-swatch").forEach((b) => b.classList.toggle("active", b.dataset.style === eff.scheme));
  }

  // ------------------------------------------------------------------ page chrome
  function updateSidebarVisibility() {
    const r = S.roots[1];
    const has = (r && r.children.some((c) => c && c.el && c.el.kind !== "empty")) || S.navVisible;
    document.getElementById("stApp").classList.toggle("no-sidebar", !has);
    const b = S.roots[2];
    const hasBottom = b && b.children.some((c) => c && c.el && c.el.kind !== "empty");
    document.getElementById("stBottom").hidden = !hasBottom;
  }

  function applyPageConfig(m) {
    if (m.title) { document.title = m.title; S.pageConfig.title = m.title; $("#stRoot-0").dataset.title = m.title; }
    if (m.icon) { setFavicon(m.icon); S.iconSetThisRun = true; }
    const app = document.getElementById("stApp");
    app.classList.toggle("layout-wide", m.layout === "wide");
    app.classList.toggle("layout-centered", m.layout !== "wide");
    if (!S.sidebarStateApplied && m.sidebarState && m.sidebarState !== "auto") {
      S.sidebarStateApplied = true;
      app.classList.toggle("sidebar-collapsed", m.sidebarState === "collapsed");
    }
  }

  function renderNav(m) {
    S.navSeen = true;
    const cur = (m.pages || []).find((p) => p.urlPath === m.current);
    S.navIcon = cur && cur.icon ? cur.icon : null;
    const nav = $("#stNav");
    nav.innerHTML = "";
    S.navVisible = m.position !== "hidden";
    if (S.navVisible) {
      (m.pages || []).forEach((p) => {
        const a = h("a", { href: BASE + p.urlPath, class: p.urlPath === m.current ? "active" : null, "data-testid": "st-nav-link" }, p.icon ? h("span", { text: p.icon }) : null, h("span", { text: p.title }));
        a.addEventListener("click", (ev) => { ev.preventDefault(); if (p.urlPath === S.page) return; setPage(p.urlPath, true); sendRerun({}); });
        nav.appendChild(a);
      });
    }
    if (!S.pageConfig.title && m.title) document.title = m.title;
    if (S.page !== m.current) setPage(m.current, false, true);
    updateSidebarVisibility();
  }

  function setPage(urlPath, push, replace) {
    S.page = urlPath || "";
    const url = BASE + S.page + location.search;
    if (push) history.pushState({ page: S.page }, "", url);
    else if (replace || location.pathname !== BASE + S.page) history.replaceState({ page: S.page }, "", url);
  }

  window.addEventListener("popstate", () => {
    S.page = pageFromLocation();
    sendRerun({});
  });

  function showToast(body, icon) {
    const t = h("div", { class: "toast", role: "status", "data-testid": "st-toast" }, icon ? h("span", { text: icon }) : null, mdEl(body));
    const x = h("button", { type: "button", text: "×", "aria-label": "Close" });
    x.addEventListener("click", () => t.remove());
    t.appendChild(x);
    $("#stToasts").appendChild(t);
    setTimeout(() => t.remove(), 4000);
  }

  function showEffect(name) {
    const chars = name === "snow" ? ["❄️", "❅", "❆"] : ["\u{1F388}", "\u{1F388}", "\u{1F389}"];
    for (let i = 0; i < 30; i++) {
      const e = h("div", { class: "effect" + (name === "snow" ? " snow" : ""), text: chars[i % chars.length] });
      e.style.left = Math.random() * 100 + "vw";
      e.style.animationDelay = Math.random() * 1.5 + "s";
      document.body.appendChild(e);
      setTimeout(() => e.remove(), 6000);
    }
  }

  // ------------------------------------------------------------------ theme & chrome events
  $("#stSettings").addEventListener("click", (ev) => { ev.stopPropagation(); $("#stSettingsPanel").hidden = !$("#stSettingsPanel").hidden; });
  document.addEventListener("click", (ev) => { if (!$("#stSettingsWrap").contains(ev.target) && !StUI.inPopup(ev.target)) { $("#stSettingsPanel").hidden = true; } });
  document.querySelectorAll("#stModeSeg button").forEach((b) => b.addEventListener("click", () => setViewer({ mode: b.dataset.mode })));

  if (darkMq) darkMq.addEventListener("change", () => { T.lastKey = null; applyTheme(); });
  $("#stRerun").addEventListener("click", () => sendRerun({}));
  $("#stSidebarClose").addEventListener("click", () => document.getElementById("stApp").classList.add("sidebar-collapsed"));
  $("#stSidebarOpen").addEventListener("click", () => document.getElementById("stApp").classList.remove("sidebar-collapsed"));
  document.addEventListener("keydown", (ev) => {
    const tag = (ev.target && ev.target.tagName) || "";
    if (/INPUT|TEXTAREA|SELECT/.test(tag) || ev.ctrlKey || ev.metaKey || ev.altKey) return;
    if (ev.key === "r" || ev.key === "R") sendRerun({});
  });

  // The logo goes to the top of the sidebar, and to the header while the sidebar is hidden or collapsed.
  function renderLogo(m) {
    for (const id of ["#stLogo", "#stHeaderLogo"]) {
      const img = h("img", { src: m.src, alt: "logo", class: "logo-img logo-" + (m.size || "medium") });
      const el = m.link ? h("a", { href: m.link, target: "_blank", rel: "noopener noreferrer" }, img) : img;
      const slot = $(id);
      slot.innerHTML = "";
      slot.appendChild(el);
      slot.hidden = false;
    }
  }

  for (const i of [0, 1, 2, 3]) S.roots[i] = makeRoot(i);
  // like Streamlit: on narrow screens the sidebar starts collapsed (it would cover the page)
  if (window.matchMedia && window.matchMedia("(max-width: 800px)").matches) document.getElementById("stApp").classList.add("sidebar-collapsed");
  $("#stRoot-0").dataset.title = document.title; // used by designs that draw a window title bar
  window.__streamlitd = S; // for debugging/tests
  connect();
})();
