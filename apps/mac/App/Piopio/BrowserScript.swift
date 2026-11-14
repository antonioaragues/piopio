/// The page script (docs/spec/22 §8), run in an isolated content world so pages can't see or change it. It defines
/// `globalThis.__piopio` once per document: the page map (refs keyed to element identity, `@(x,y)` per element, secret
/// fields left out), reading as markdown, and where an element is. From the W0 spike (22 §13), with the reading added.
enum BrowserScript {
    static let source = ##"""
(() => {
	if (globalThis.__piopio) return;

	const SECRET_AUTOCOMPLETE = /\b(current-password|new-password|one-time-code|cc-[a-z-]+)\b/i;
	const ROLES = new Set(["button", "link", "checkbox", "radio", "switch", "tab", "menuitem", "menuitemcheckbox", "menuitemradio",
		"option", "combobox", "textbox", "searchbox", "slider", "spinbutton", "listbox", "treeitem"]);
	const st = { next: 1, byEl: new WeakMap(), byRef: new Map() };

	function refFor(el) {
		let r = st.byEl.get(el);
		if (!r) { r = "e" + st.next++; st.byEl.set(el, r); }
		st.byRef.set(r, new WeakRef(el));
		return r;
	}

	function isSecret(el) {
		if (el.tagName !== "INPUT" && el.tagName !== "TEXTAREA") return false;
		if ((el.type || "").toLowerCase() === "password") return true;
		return SECRET_AUTOCOMPLETE.test(el.getAttribute("autocomplete") || "");
	}

	function implicitRole(el) {
		const explicit = (el.getAttribute("role") || "").split(/\s+/)[0];
		if (explicit) return explicit;
		switch (el.tagName) {
			case "A": return el.hasAttribute("href") ? "link" : "";
			case "BUTTON": case "SUMMARY": return "button";
			case "SELECT": return el.multiple ? "listbox" : "combobox";
			case "TEXTAREA": return "textbox";
			case "INPUT": {
				const t = (el.type || "text").toLowerCase();
				if (t === "hidden") return "";
				if (["button", "submit", "reset", "image", "file"].includes(t)) return "button";
				if (t === "checkbox" || t === "radio") return t;
				if (t === "range") return "slider";
				if (t === "number") return "spinbutton";
				if (t === "search") return "searchbox";
				return "textbox";
			}
		}
		if (el.isContentEditable && !el.parentElement?.isContentEditable) return "textbox";
		return "";
	}

	function clean(s, max = 80) {
		s = (s || "").replace(/\s+/g, " ").trim();
		return s.length > max ? s.slice(0, max - 1) + "…" : s;
	}

	function nameOf(el, doc) {
		const by = el.getAttribute("aria-labelledby");
		if (by) {
			const t = by.split(/\s+/).map((id) => doc.getElementById(id)?.innerText || "").join(" ");
			if (clean(t)) return clean(t);
		}
		const aria = el.getAttribute("aria-label");
		if (clean(aria)) return clean(aria);
		if (el.labels && el.labels.length) {
			const t = [...el.labels].map((l) => l.innerText).join(" ");
			if (clean(t)) return clean(t);
		}
		if (el.tagName === "INPUT" && ["button", "submit", "reset"].includes(el.type) && el.value) return clean(el.value);
		if (clean(el.innerText)) return clean(el.innerText);
		const img = el.querySelector?.("img[alt]");
		if (img && clean(img.alt)) return clean(img.alt);
		return clean(el.getAttribute("placeholder") || el.getAttribute("title") || el.getAttribute("name") || "");
	}

	function visible(el, rect) {
		if (rect.width < 1 || rect.height < 1) return false;
		const cs = getComputedStyle(el);
		return cs.visibility !== "hidden" && cs.display !== "none" && parseFloat(cs.opacity || "1") > 0.05;
	}

	function clickableByStyle(el) {
		if (getComputedStyle(el).cursor !== "pointer") return false;
		const p = el.parentElement;
		return !p || getComputedStyle(p).cursor !== "pointer";
	}

	function isInteractive(el) {
		const role = implicitRole(el);
		if (role && (ROLES.has(role) || el.tagName === "A" || el.tagName === "BUTTON")) return role;
		if (el.hasAttribute("onclick") || (el.tabIndex >= 0 && el.hasAttribute("tabindex"))) return role || "clickable";
		if (["DIV", "SPAN", "LI", "IMG", "SVG", "TD"].includes(el.tagName) && clickableByStyle(el)) return "clickable";
		return "";
	}

	function* walk(root, doc, ox, oy, stats) {
		const tw = doc.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
		for (let n = tw.currentNode; n; n = tw.nextNode()) {
			if (n.nodeType !== 1) continue;
			yield [n, doc, ox, oy];
			if (n.shadowRoot) yield* walk(n.shadowRoot, doc, ox, oy, stats);
			if (n.tagName === "IFRAME" || n.tagName === "FRAME") {
				let inner = null;
				try { inner = n.contentDocument; } catch { inner = null; }
				const r = n.getBoundingClientRect();
				if (inner && inner.documentElement) yield* walk(inner.documentElement, inner, ox + r.left, oy + r.top, stats);
				else if (r.width > 1 && r.height > 1) stats.crossOriginFrames++;
			}
		}
	}

	function describe(el, role, doc) {
		const name = nameOf(el, doc);
		const s = {};
		if (el.disabled || el.getAttribute("aria-disabled") === "true") s.disabled = true;
		if (role === "checkbox" || role === "radio" || role === "switch") s.checked = el.checked ?? el.getAttribute("aria-checked") === "true";
		const exp = el.getAttribute("aria-expanded");
		if (exp) s.expanded = exp === "true";
		if (el.getAttribute("aria-selected") === "true") s.selected = true;
		if (doc.activeElement === el) s.focused = true;
		let value;
		if (["textbox", "searchbox", "combobox", "spinbutton"].includes(role) && "value" in el && el.value) value = clean(el.value, 60);
		if (el.tagName === "SELECT" && el.selectedOptions?.[0]) value = clean(el.selectedOptions[0].text, 60);
		if (el.tagName === "A" && el.getAttribute("href") && !el.getAttribute("href").startsWith("javascript:")) s.href = el.getAttribute("href").slice(0, 80);
		return { name, value, state: s };
	}

	function map(opts = {}) {
		const all = opts.filter === "all";
		const vw = innerWidth, vh = innerHeight;
		const stats = { crossOriginFrames: 0 };
		const lines = [], secrets = [];
		let offscreen = 0;
		for (const [el, doc, ox, oy] of walk(document.documentElement, document, 0, 0, stats)) {
			if (isSecret(el)) {
				if (visible(el, el.getBoundingClientRect())) secrets.push(nameOf(el, doc) || (el.type === "password" ? "password" : el.getAttribute("autocomplete")));
				continue;
			}
			const role = isInteractive(el);
			if (!role) continue;
			const r = el.getBoundingClientRect();
			if (!visible(el, r)) continue;
			const x = Math.round(ox + r.left + r.width / 2), y = Math.round(oy + r.top + r.height / 2);
			const inView = x >= 0 && y >= 0 && x <= vw && y <= vh;
			if (!inView) { offscreen++; if (!all) continue; }
			const d = describe(el, role, doc);
			if (!d.name && !d.value && role === "clickable") continue;
			const flags = Object.entries(d.state).map(([k, v]) => (v === true ? k : `${k}=${JSON.stringify(v)}`)).join(" ");
			lines.push(`[${refFor(el)}] ${role} ${JSON.stringify(d.name)}${d.value ? ` value=${JSON.stringify(d.value)}` : ""}${flags ? " " + flags : ""} @(${x},${y})`);
		}
		if (secrets.length) lines.push(`(${secrets.length} secret field${secrets.length > 1 ? "s" : ""} hidden: ${secrets.map((s) => JSON.stringify(s)).join(", ")}; the user fills these)`);
		if (offscreen && !all) lines.push(`(${offscreen} more below or beside the screen: scroll, or map with filter "all")`);
		if (stats.crossOriginFrames) lines.push(`(${stats.crossOriginFrames} embedded frame${stats.crossOriginFrames > 1 ? "s" : ""} from other sites not mapped)`);
		return lines.join("\n");
	}

	function resolve(ref) {
		const el = st.byRef.get(ref)?.deref();
		return el && el.isConnected ? el : null;
	}

	function rect(ref) {
		const el = resolve(ref);
		if (!el) return { error: "stale" };
		el.scrollIntoView({ block: "center", inline: "center" });
		const r = el.getBoundingClientRect();
		return { x: r.left, y: r.top, width: r.width, height: r.height };
	}

	function scroll(by, ref) {
		const target = ref ? resolve(ref) : null;
		if (ref && !target) return { error: "stale" };
		const amount = typeof by === "number" ? by : Math.round(innerHeight * 0.85);
		if (target) target.scrollBy({ top: amount });
		else scrollBy({ top: amount });
		return { y: Math.round(scrollY), height: Math.round(document.documentElement.scrollHeight) };
	}

	// Reading as markdown: headings, paragraphs, lists, links, code, quotes and tables, skipping what isn't shown.
	const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "CANVAS", "IFRAME", "OBJECT", "HEAD", "INPUT", "SELECT", "TEXTAREA", "BUTTON"]);
	function shown(el) {
		const cs = getComputedStyle(el);
		return cs.display !== "none" && cs.visibility !== "hidden";
	}
	function inline(node) {
		let out = "";
		for (const n of node.childNodes) {
			if (n.nodeType === 3) { out += n.nodeValue.replace(/\s+/g, " "); continue; }
			if (n.nodeType !== 1 || SKIP.has(n.tagName) || !shown(n)) continue;
			const t = n.tagName;
			if (t === "BR") out += "\n";
			else if (t === "A") {
				const text = inline(n).trim();
				const href = n.href && !n.getAttribute("href").startsWith("javascript:") ? n.href : "";
				out += text && href ? `[${text}](${href})` : text;
			} else if (t === "STRONG" || t === "B") { const x = inline(n).trim(); if (x) out += `**${x}**`; }
			else if (t === "EM" || t === "I") { const x = inline(n).trim(); if (x) out += `_${x}_`; }
			else if (t === "CODE") out += "`" + n.textContent + "`";
			else if (t === "IMG") { if (n.alt) out += `![${clean(n.alt, 100)}]`; }
			else out += inline(n);
		}
		return out;
	}
	function isBlock(el) {
		const d = getComputedStyle(el).display;
		return !d.startsWith("inline") && d !== "contents" || ["DIV", "P", "SECTION", "ARTICLE", "UL", "OL", "TABLE", "PRE", "BLOCKQUOTE", "H1", "H2", "H3", "H4", "H5", "H6", "LI", "HR", "FIGURE", "HEADER", "FOOTER", "MAIN", "NAV", "ASIDE", "FORM", "DL", "DT", "DD"].includes(el.tagName);
	}
	function block(el, out, depth) {
		if (out.length > 4000) return;
		const t = el.tagName;
		if (/^H[1-6]$/.test(t)) { const x = inline(el).trim(); if (x) out.push("#".repeat(+t[1]) + " " + x); return; }
		if (t === "PRE") { out.push("```\n" + el.innerText.replace(/\n$/, "") + "\n```"); return; }
		if (t === "HR") { out.push("---"); return; }
		if (t === "BLOCKQUOTE") { const inner = []; children(el, inner, depth); if (inner.length) out.push(inner.map((l) => "> " + l.replace(/\n/g, "\n> ")).join("\n>\n")); return; }
		if (t === "UL" || t === "OL") {
			let i = 0;
			const items = [];
			for (const li of el.children) {
				if (li.tagName !== "LI" || !shown(li)) continue;
				i++;
				const nested = [];
				const own = [];
				for (const c of li.childNodes) {
					if (c.nodeType === 1 && (c.tagName === "UL" || c.tagName === "OL")) block(c, nested, depth + 1);
					else own.push(c);
				}
				const text = own.map((c) => (c.nodeType === 3 ? c.nodeValue.replace(/\s+/g, " ") : c.nodeType === 1 && !SKIP.has(c.tagName) && shown(c) ? inlineOf(c) : "")).join("").trim();
				const lead = "  ".repeat(depth) + (t === "OL" ? `${i}. ` : "- ");
				if (text) items.push(lead + text);
				items.push(...nested);
			}
			if (items.length) out.push(items.join("\n"));
			return;
		}
		if (t === "TABLE") {
			const rows = [...el.querySelectorAll("tr")].slice(0, 200).map((tr) => "| " + [...tr.children].map((c) => inline(c).trim().replace(/\|/g, "\\|") || " ").join(" | ") + " |");
			if (rows.length) {
				const cols = (rows[0].match(/ \| /g) || []).length + 1;
				rows.splice(1, 0, "|" + " --- |".repeat(cols));
				out.push(rows.join("\n"));
			}
			return;
		}
		const hasBlocks = [...el.children].some((c) => !SKIP.has(c.tagName) && shown(c) && isBlock(c));
		if (hasBlocks) children(el, out, depth);
		else { const x = inline(el).replace(/[ \t]+\n/g, "\n").trim(); if (x) out.push(x); }
	}
	function inlineOf(el) {
		const wrap = { childNodes: [el] };
		return inline(wrap);
	}
	function children(el, out, depth) {
		let pending = "";
		const flush = () => { const x = pending.trim(); if (x) out.push(x); pending = ""; };
		for (const c of el.childNodes) {
			if (c.nodeType === 3) { pending += c.nodeValue.replace(/\s+/g, " "); continue; }
			if (c.nodeType !== 1 || SKIP.has(c.tagName) || !shown(c)) continue;
			if (c.shadowRoot) { flush(); children(c.shadowRoot, out, depth); continue; }
			if (isBlock(c)) { flush(); block(c, out, depth); }
			else pending += inlineOf(c);
		}
		flush();
	}
	function read(selector) {
		// A selector reads every match (up to 200), in page order: "p" or ".result" usually means all of them.
		const roots = selector ? [...document.querySelectorAll(selector)].slice(0, 200) : [document.querySelector("main, article, [role=main]") || document.body];
		if (!roots.length) return { error: `Nothing on the page matches ${selector}.` };
		const out = [];
		for (const root of roots) block(root, out, 0);
		let text = out.join("\n\n").replace(/\n{3,}/g, "\n\n");
		const max = 60000;
		const truncated = text.length > max;
		if (truncated) text = text.slice(0, max);
		return { text, truncated };
	}

	// Where to click a ref, re-resolved now: scrolled into view, with what's on top of that point (pi-browser-harness's
	// check, through open shadow roots).
	function point(ref) {
		const el = resolve(ref);
		if (!el) return { error: "stale" };
		el.scrollIntoView({ block: "center", inline: "center" });
		const r = el.getBoundingClientRect();
		const x = r.left + r.width / 2, y = r.top + r.height / 2;
		let top = document.elementFromPoint(x, y);
		while (top?.shadowRoot) {
			const inner = top.shadowRoot.elementFromPoint(x, y);
			if (!inner || inner === top) break;
			top = inner;
		}
		const within = (a, b) => { for (let n = b; n; n = n.parentNode || n.host) if (n === a) return true; return false; };
		const covered = !!top && top !== el && !within(el, top) && !within(top, el);
		return { x, y, secret: isSecret(el), covered, coveredBy: covered ? clean(top.tagName.toLowerCase() + " " + (top.innerText || top.getAttribute("aria-label") || ""), 60) : undefined,
			tag: el.tagName, editable: el.isContentEditable || ["INPUT", "TEXTAREA"].includes(el.tagName), name: nameOf(el, el.ownerDocument), role: isInteractive(el) || el.tagName.toLowerCase() };
	}

	function secretAtFocus() {
		const el = document.activeElement;
		return !!el && isSecret(el);
	}

	// Selects a field's text, so typing replaces it.
	function selectContents(ref) {
		const el = resolve(ref);
		if (!el) return { error: "stale" };
		if (typeof el.select === "function") el.select();
		else if (el.isContentEditable) { const r = document.createRange(); r.selectNodeContents(el); const s = getSelection(); s.removeAllRanges(); s.addRange(r); }
		return { ok: true };
	}

	function value(ref) {
		const el = resolve(ref);
		if (!el) return { error: "stale" };
		if (isSecret(el)) return { error: "secret" };
		return { value: "value" in el ? el.value : el.innerText, focused: el.ownerDocument.activeElement === el };
	}

	// The fallback when typed keys didn't take (some frameworks): the native setter, then input and change events.
	function setValue(ref, text) {
		const el = resolve(ref);
		if (!el) return { error: "stale" };
		if (isSecret(el)) return { error: "secret" };
		if (el.isContentEditable) el.innerText = text;
		else {
			const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
			Object.getOwnPropertyDescriptor(proto, "value").set.call(el, text);
		}
		el.dispatchEvent(new Event("input", { bubbles: true }));
		el.dispatchEvent(new Event("change", { bubbles: true }));
		return { value: "value" in el ? el.value : el.innerText };
	}

	function choose(ref, wanted) {
		const el = resolve(ref);
		if (!el) return { error: "stale" };
		if (el.tagName !== "SELECT") return { error: "not a select" };
		const w = String(wanted).trim().toLowerCase();
		const opt = [...el.options].find((o) => o.value.toLowerCase() === w) || [...el.options].find((o) => o.text.trim().toLowerCase() === w) || [...el.options].find((o) => o.text.trim().toLowerCase().includes(w));
		if (!opt) return { error: "no option", options: [...el.options].slice(0, 30).map((o) => o.text.trim()) };
		el.value = opt.value;
		el.dispatchEvent(new Event("input", { bubbles: true }));
		el.dispatchEvent(new Event("change", { bubbles: true }));
		return { value: opt.text.trim() };
	}

	function checked(ref) {
		const el = resolve(ref);
		if (!el) return { error: "stale" };
		return { checked: el.checked ?? el.getAttribute("aria-checked") === "true" };
	}

	function hasText(text) {
		return (document.body?.innerText || "").toLowerCase().includes(String(text).toLowerCase());
	}

	globalThis.__piopio = { map, rect, scroll, read, hasText, point, secretAtFocus, selectContents, value, setValue, choose, checked };
})();
"""##
}
