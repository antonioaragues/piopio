/**
 * The doc comments of index.ts by schema path, for the generated Swift (src/swift.ts): TypeBox keeps only
 * `description`, so the `/** … *\/` comments over exports, properties, union branches and methods are read from the
 * source. Paths are the generator's: an export's name (or "method.params", "method.result", "method.notification"),
 * then property names, and a tagged union's tag value for its branch ("ToolDetails.task.status").
 */
import { readFileSync } from "node:fs";
import ts from "typescript";

export function protocolDocs(file: URL): Map<string, string> {
	const text = readFileSync(file, "utf8");
	const sf = ts.createSourceFile(file.pathname, text, ts.ScriptTarget.Latest, true);
	const docs = new Map<string, string>();
	const consts = new Map<string, { init: ts.Expression; exported: boolean }>();
	for (const st of sf.statements) {
		if (!ts.isVariableStatement(st)) continue;
		const exported = st.modifiers?.some((m) => m.kind === ts.SyntaxKind.ExportKeyword) ?? false;
		for (const d of st.declarationList.declarations) if (d.initializer && ts.isIdentifier(d.name)) consts.set(d.name.text, { init: d.initializer, exported });
	}
	const set = (path: string, node: ts.Node) => {
		const doc = jsdoc(text, node);
		if (doc) docs.set(path, doc);
	};
	const callee = (n: ts.Node) => (ts.isCallExpression(n) ? n.expression.getText(sf) : "");
	const bare = (n: ts.Expression): ts.Expression => (ts.isSatisfiesExpression(n) || ts.isAsExpression(n) || ts.isParenthesizedExpression(n) ? bare(n.expression) : n);
	const name = (p: ts.ObjectLiteralElementLike) => (p.name && (ts.isIdentifier(p.name) || ts.isStringLiteral(p.name)) ? p.name.text : undefined);

	/** Walks a schema expression at `path`, recording the docs of what it holds. */
	function walk(n: ts.Expression, path: string): void {
		n = bare(n);
		if (ts.isIdentifier(n)) {
			const c = consts.get(n.text);
			if (c && !c.exported) walk(c.init, path); // a private helper schema (ContextBreakdown); an export is its own root
			return;
		}
		if (!ts.isCallExpression(n)) return;
		const args = n.arguments;
		switch (callee(n)) {
			case "named":
				return walk(args[1]!, path);
			case "Type.Optional":
			case "Type.Array":
			case "Type.Partial":
				return walk(args[0]!, path);
			case "Type.Record":
				return walk(args[1]!, path);
			case "Type.Intersect":
				if (args[0] && ts.isArrayLiteralExpression(args[0])) for (const e of args[0].elements) walk(e, path);
				return;
			case "Type.Object":
				if (args[0] && ts.isObjectLiteralExpression(args[0]))
					for (const p of args[0].properties) {
						const key = name(p);
						if (!key || !ts.isPropertyAssignment(p)) continue;
						set(`${path}.${key}`, p);
						walk(p.initializer, `${path}.${key}`);
					}
				return;
			case "Type.Union": {
				if (!args[0] || !ts.isArrayLiteralExpression(args[0])) return;
				for (const e of args[0].elements) {
					const tag = tagOf(e);
					if (tag === undefined) walk(e, path); // `T | null`
					else {
						set(`${path}.${tag}`, e);
						walk(e, `${path}.${tag}`);
					}
				}
			}
		}
	}
	/** A union branch's tag ("type" or "kind" as a literal), when it's an inline object. */
	function tagOf(e: ts.Expression): string | undefined {
		e = bare(e);
		if (callee(e) !== "Type.Object" || !ts.isCallExpression(e)) return undefined;
		const obj = e.arguments[0];
		if (!obj || !ts.isObjectLiteralExpression(obj)) return undefined;
		for (const p of obj.properties) {
			const key = name(p);
			if ((key === "type" || key === "kind") && ts.isPropertyAssignment(p) && callee(p.initializer) === "Type.Literal" && ts.isCallExpression(p.initializer)) {
				const lit = p.initializer.arguments[0];
				if (lit && ts.isStringLiteral(lit)) return lit.text;
			}
		}
		return undefined;
	}

	for (const st of sf.statements) {
		if (!ts.isVariableStatement(st)) continue;
		for (const d of st.declarationList.declarations) {
			if (!ts.isIdentifier(d.name) || !d.initializer) continue;
			const id = d.name.text;
			if (!consts.get(id)?.exported) continue;
			const init = bare(d.initializer);
			if (id === "methods" || id === "reverseMethods" || id === "notifications") {
				if (!ts.isObjectLiteralExpression(init)) continue;
				for (const m of init.properties) {
					const method = name(m);
					if (!method || !ts.isPropertyAssignment(m)) continue;
					if (id === "notifications") {
						set(`${method}.notification`, m);
						walk(m.initializer, `${method}.notification`);
						continue;
					}
					set(method, m); // the method's own doc, for its params' and result's types
					const parts = bare(m.initializer);
					if (!ts.isObjectLiteralExpression(parts)) continue;
					for (const p of parts.properties) {
						const part = name(p);
						if ((part !== "params" && part !== "result") || !ts.isPropertyAssignment(p)) continue;
						set(`${method}.${part}`, p);
						walk(p.initializer, `${method}.${part}`);
					}
				}
				continue;
			}
			set(id, st);
			walk(init, id);
		}
	}
	return docs;
}

/** The `/** … *\/` comments right before `node`, as plain lines. */
function jsdoc(text: string, node: ts.Node): string | undefined {
	const blocks = (ts.getLeadingCommentRanges(text, node.getFullStart()) ?? [])
		.map((r) => text.slice(r.pos, r.end))
		.filter((c) => c.startsWith("/**"))
		.map((c) =>
			c
				.slice(3, -2)
				.split("\n")
				.map((l) => l.replace(/^\s*\* ?/, "").trimEnd())
				.join("\n")
				.trim(),
		)
		.filter(Boolean);
	return blocks.length ? blocks.join("\n") : undefined;
}
