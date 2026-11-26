/**
 * The Mac app's protocol types, generated from the protocol's JSON Schema (src/schema.ts) so the two sides can't drift:
 * apps/mac/Sources/PiopioKit/Protocol.generated.swift is this, written by `pnpm schema`; test/swift.test.ts fails when
 * it's stale. What the schema can't say (helpers, convenience initializers) stays hand-written in Protocol.swift.
 *
 * How schemas become Swift (docs/spec/03-engine-protocol.md, "Swift types"):
 * - A schema with a `title` (every export of index.ts, `named("X", …)`) is one top-level type, X (`renames` aside).
 * - A method's params and result are `<Method>Params` / `<Method>Result` ("sessions.pr.get" → SessionsPrGetParams),
 *   or the name src/swift-names.ts gives them. Several methods may share a Swift type when it fits each of them
 *   (checked here: a params type sends nothing a method doesn't take, a result type reads nothing it doesn't send).
 * - Anything else is nested in the type that holds it, named after its property ("status" → Status, "items" → Item).
 * - Objects are structs; unions of strings are String enums; unions of objects tagged by a constant property are
 *   enums with a case per tag (a titled branch carries its type, another its fields); `T | null` is `T?`.
 * - Type.Number is Double, Type.Integer is Int; Type.Unknown is JSONValue; records are [String: T].
 */
import { protocolSchema } from "./schema.js";
import { reverseMethods } from "./index.js";
import { swiftNames } from "./swift-names.js";

export type Schema = {
	title?: string;
	description?: string;
	type?: string;
	const?: unknown;
	properties?: Record<string, Schema>;
	required?: string[];
	anyOf?: Schema[];
	allOf?: Schema[];
	items?: Schema;
	patternProperties?: Record<string, Schema>;
};

const KEYWORDS = new Set(
	"associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while Any as await false is nil self Self super throws true try".split(" "),
);
/** Names a nested type can't have, or would shadow inside its parent. */
const RESERVED_TYPE_NAMES = new Set(["Type", "Protocol", "Self", "Any", "String", "Int", "Double", "Bool", "Array", "Dictionary", "Optional", "JSONValue", "CodingKeys", "Nullable"]);
/** Top-level names that would shadow Swift, Foundation or SwiftUI types the app uses. */
const TAKEN_TOP_LEVEL = new Set(["Task", "Result", "Error", "Data", "URL", "Date", "Calendar", "Process", "Timer", "Notification", "Bundle", "Locale", "Text", "Image", "Color", "View", "Group", "Section", "Label", "Link", "Menu", "Table", "Form", "List", "Grid", "Button", "Toggle", "Picker", "Path", "Shape", "LibraryItem", "Set", "Range"]);

const ident = (name: string) => (KEYWORDS.has(name) ? `\`${name}\`` : name);
const words = (s: string) => s.split(/[^A-Za-z0-9]+/).filter(Boolean);
const upperFirst = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const pascal = (s: string) => words(s).map(upperFirst).join("");
/** A string enum's case name: "pending_approval" → pendingApproval, "item.added" → itemAdded. */
function caseName(raw: string): string {
	const named = swiftNames.cases[raw];
	if (named) return named;
	const p = pascal(raw);
	const name = p.charAt(0).toLowerCase() + p.slice(1);
	if (!/^[A-Za-z_]/.test(name)) throw new Error(`"${raw}" can't be a Swift case name: give it one in swift-names.ts \`cases\``);
	return name;
}
/** "items" → Item, "entries" → Entry, "statuses" → Status. */
function singular(word: string): string {
	if (word === "lenses") return "lens";
	if (/ies$/.test(word)) return word.slice(0, -3) + "y";
	if (/(ss|sh|ch|x|us)es$/.test(word)) return word.slice(0, -2);
	if (/(ss|us)$/.test(word)) return word;
	if (/s$/.test(word)) return word.slice(0, -1);
	return word;
}
const key = (s: Schema) => JSON.stringify(s);
const doc = (text: string | undefined, indent: string) => (text ? text.split("\n").map((l) => `${indent}/// ${l}`.trimEnd()).join("\n") + "\n" : "");

/** A reference to a top-level type, resolved once every type is known (a nested type of the same name shadows it). */
const ref = (name: string) => `\u0001${name}\u0002`;

/** `tristate`: optional and nullable in a type the app sends, so absent (leave it) and null (clear it) differ: `Nullable<T>?`. */
type Field = { json: string; name: string; type: string; optional: boolean; nullable: boolean; tristate?: boolean; doc?: string };
type Scope = { name: string; path: string; parent?: Scope; nested: Map<string, Decl> };
type Decl =
	| { kind: "struct"; scope: Scope; schemaKey: string; fields: Field[]; consts: { json: string; value: unknown }[]; embeds: { name: string; type: string }[]; doc?: string }
	| { kind: "enum"; scope: Scope; schemaKey: string; cases: { raw: string; name: string }[]; doc?: string }
	| { kind: "union"; scope: Scope; schemaKey: string; tag: string; open: boolean; cases: UnionCase[]; doc?: string }
	| { kind: "choice"; scope: Scope; schemaKey: string; literals: { raw: string; name: string }[]; types: { name: string; type: string }[]; doc?: string }
	| { kind: "empty"; scope: Scope; schemaKey: string };
type UnionCase = { raw: string; name: string; type?: string; fields: Field[] };

/** One type's use by a method: which direction it travels in, so a shared Swift type is checked against each. */
type Use = { method: string; schema: Schema; direction: "send" | "receive" };

export class SwiftGenerator {
	private readonly top = new Map<string, Decl>();
	private readonly module: Scope = { name: "", path: "", nested: this.top };
	private readonly uses = new Map<string, Use[]>();
	/** Each struct field's Swift path ("SessionState.Context.window") and its schema path ("SessionState.context.window"). */
	readonly trace = new Map<string, string>();
	/** The swift-names.ts entries used, so one that names nothing (a typo, a path that moved) fails the build. */
	private readonly used = new Set<string>();
	readonly tables: Record<"definitions" | "params" | "results" | "notifications" | "reverseParams" | "reverseResults", [string, string][]> = { definitions: [], params: [], results: [], notifications: [], reverseParams: [], reverseResults: [] };

	constructor(private readonly definitions: Record<string, Schema>) {}

	run(): void {
		const reverse = new Set(Object.keys(reverseMethods));
		for (const [def, schema] of Object.entries(this.definitions)) {
			const dot = def.lastIndexOf(".");
			if (dot < 0) {
				this.tables.definitions.push([def, this.named(schema)]);
				continue;
			}
			const method = def.slice(0, dot);
			const part = def.slice(dot + 1) as "params" | "result" | "notification";
			const configured = part === "notification" ? swiftNames.notifications[method] : swiftNames.methods[method]?.[part];
			if (configured) this.used.add(part === "notification" ? `notification:${method}` : `method:${method}`);
			const fallback = `${pascal(method)}${part === "params" ? "Params" : part === "result" ? "Result" : "Notification"}`;
			const isReverse = reverse.has(method);
			// What the app sends: a method's params, a reverse request's result. The rest it receives.
			const direction = (part === "params") !== isReverse ? "send" : "receive";
			const type = this.root(configured ?? fallback, schema, { method: `${method}.${part}`, schema, direction });
			const table = part === "notification" ? "notifications" : isReverse ? (part === "params" ? "reverseParams" : "reverseResults") : part === "params" ? "params" : "results";
			this.tables[table].push([method, type]);
		}
		for (const [name, uses] of this.uses) this.checkShared(name, uses);
		const unused = [
			...Object.keys(swiftNames.methods).filter((m) => !this.used.has(`method:${m}`)),
			...Object.keys(swiftNames.notifications).filter((m) => !this.used.has(`notification:${m}`)),
			...[...Object.keys(swiftNames.nested), ...Object.keys(swiftNames.topLevel)].filter((p) => !this.used.has(`path:${p}`)),
			...Object.keys(swiftNames.renames).filter((t) => !this.used.has(`rename:${t}`)),
			...swiftNames.openUnions.filter((u) => !this.used.has(`open:${u}`)),
		];
		if (unused.length) throw new Error(`swift-names.ts names what the schema doesn't have: ${unused.join(", ")}`);
	}

	/** A method's params or result: its titled type, an empty object, or a new type by `name`. */
	private root(name: string, schema: Schema, use: Use): string {
		if (name === "JSONValue") return "JSONValue";
		const merged = this.merge(schema);
		if (merged.title) return this.named(merged);
		if (isEmpty(merged)) return this.empty();
		const list = this.uses.get(name) ?? [];
		list.push(use);
		this.uses.set(name, list);
		if (list.length === 1) this.declare(this.module, name, schema, undefined, use.method); // the others: checkShared
		return ref(name);
	}

	/** A titled schema's top-level type. */
	private named(schema: Schema): string {
		const title = schema.title!;
		if (swiftNames.renames[title]) this.used.add(`rename:${title}`);
		const name = swiftNames.renames[title] ?? title;
		const existing = this.top.get(name);
		const k = key(schema);
		if (existing) {
			if (existing.schemaKey !== k) throw new Error(`Two different schemas are titled "${title}": give one another name in index.ts`);
			return ref(name);
		}
		if (isPrimitive(schema)) return this.type({ ...schema, title: undefined }, this.module, title, title).type;
		this.declare(this.module, name, schema, schema.description, title);
		return ref(name);
	}

	private empty(): string {
		if (!this.top.has("Empty")) this.top.set("Empty", { kind: "empty", scope: { name: "Empty", path: "Empty", parent: this.module, nested: new Map() }, schemaKey: "{}" });
		return ref("Empty");
	}

	/** Declares `name` in `parent` for `schema` (an object, a union, a string enum), or reuses an equal one there. */
	private declare(parent: Scope, name: string, schema: Schema, description: string | undefined, path: string): void {
		if (parent === this.module && TAKEN_TOP_LEVEL.has(name)) throw new Error(`${path}: "${name}" would shadow a Swift or SwiftUI type; rename it in swift-names.ts \`renames\``);
		if (parent !== this.module && RESERVED_TYPE_NAMES.has(name)) throw new Error(`${path}: a nested type can't be called "${name}"; name it in swift-names.ts \`nested\``);
		const k = key(schema);
		const existing = parent.nested.get(name);
		if (existing) {
			if (existing.schemaKey !== k) throw new Error(`${path}: "${parent.path ? parent.path + "." : ""}${name}" is already a different type; name one in swift-names.ts \`nested\``);
			return;
		}
		if (parent.name === name) throw new Error(`${path}: a type nested in ${name} can't be called ${name}; name it in swift-names.ts \`nested\``);
		const scope: Scope = { name, path: parent.path ? `${parent.path}.${name}` : name, parent, nested: new Map() };
		if (schema.allOf?.some((part) => part.title)) {
			// An intersection with a named type (Type.Intersect([AutomationChange, …])): that type embedded whole, and the
			// other parts' fields beside it. Encoded after it, so a field it tightens ("prompt", required) wins.
			const decl: Decl = { kind: "struct", scope, schemaKey: k, fields: [], consts: [], embeds: [], doc: description };
			parent.nested.set(name, decl);
			for (const part of schema.allOf) {
				if (!part.title) this.fields(this.merge(part), scope, path, decl);
				else {
					const swift = swiftNames.renames[part.title] ?? part.title;
					decl.embeds.push({ name: swift.charAt(0).toLowerCase() + swift.slice(1), type: this.named(part) });
				}
			}
			return;
		}
		schema = this.merge(schema);
		const strings = stringLiterals(schema);
		if (strings) {
			parent.nested.set(name, { kind: "enum", scope, schemaKey: k, cases: strings.map((raw) => ({ raw, name: caseName(raw) })), doc: description });
			return;
		}
		if (schema.anyOf) {
			parent.nested.set(name, this.union(scope, schema, k, description, path));
			return;
		}
		if (schema.type !== "object") throw new Error(`${path}: can't declare a type for ${k.slice(0, 120)}`);
		const decl: Decl = { kind: "struct", scope, schemaKey: k, fields: [], consts: [], embeds: [], doc: description };
		parent.nested.set(name, decl); // before its fields, so a field's types see it
		this.fields(schema, scope, path, decl);
	}

	private fields(schema: Schema, scope: Scope, path: string, into: { fields: Field[]; consts?: { json: string; value: unknown }[] }, skip?: string): void {
		const required = new Set(schema.required ?? []);
		for (const [json, child] of Object.entries(schema.properties ?? {})) {
			if (json === skip) continue;
			if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(json)) throw new Error(`${path}.${json}: not a Swift name`);
			if ("const" in child && required.has(json)) {
				if (!into.consts) throw new Error(`${path}.${json}: a constant in a union's branch`);
				into.consts.push({ json, value: child.const });
				continue;
			}
			const t = this.type(child, scope, json, `${path}.${json}`);
			this.trace.set(`${scope.path}.${json}`, `${path}.${json}`);
			into.fields.push({ json, name: ident(json), type: t.type, optional: !required.has(json), nullable: t.nullable, doc: child.description });
		}
	}

	private union(scope: Scope, schema: Schema, k: string, description: string | undefined, path: string): Decl {
		const branches = schema.anyOf!.map((b) => this.merge(b));
		const tag = tagOf(branches);
		if (tag) {
			const open = swiftNames.openUnions.includes(scope.path);
			if (open) this.used.add(`open:${scope.path}`);
			const decl: Decl = { kind: "union", scope, schemaKey: k, tag, open, cases: [], doc: description };
			for (const b of branches) {
				const raw = String(b.properties![tag]!.const);
				const c: UnionCase = { raw, name: caseName(raw), fields: [] };
				if (b.title) c.type = this.named(b);
				else this.fields(b, scope, `${path}.${raw}`, c, tag);
				decl.cases.push(c);
			}
			return decl;
		}
		// Strings and objects (UtilityChoice: "auto" | "off" | ModelRef): each string a case, each titled object a case.
		const decl: Decl = { kind: "choice", scope, schemaKey: k, literals: [], types: [], doc: description };
		for (const b of branches) {
			if (typeof b.const === "string") decl.literals.push({ raw: b.const, name: caseName(b.const) });
			else if (b.title) {
				const type = this.named(b);
				const name = swiftNames.renames[b.title] ?? b.title;
				decl.types.push({ name: swiftNames.cases[`${scope.path}.${name}`] ?? name.charAt(0).toLowerCase() + name.slice(1), type });
			} else throw new Error(`${path}: a union of strings and objects needs each object titled (named in index.ts)`);
		}
		return decl;
	}

	/** The Swift type of `schema`, found at property `prop` of `scope`. */
	private type(schema: Schema, scope: Scope, prop: string, path: string): { type: string; nullable: boolean } {
		const override = swiftNames.nested[path];
		if (override) this.used.add(`path:${path}`);
		if (override === "JSONValue") return { type: "JSONValue", nullable: false };
		if (schema.allOf?.some((part) => part.title)) return { type: this.nested(schema, scope, prop, path), nullable: false };
		schema = this.merge(schema);
		if (schema.anyOf) {
			const rest = schema.anyOf.filter((b) => b.type !== "null");
			if (rest.length < schema.anyOf.length) {
				const inner = rest.length === 1 ? rest[0]! : { ...schema, anyOf: rest };
				return { type: this.type(inner, scope, prop, path).type, nullable: true };
			}
		}
		if (schema.title) return { type: this.named(schema), nullable: false };
		if (stringLiterals(schema) || schema.anyOf || (schema.type === "object" && schema.properties && !isEmpty(schema))) {
			return { type: this.nested(schema, scope, prop, path), nullable: false };
		}
		switch (schema.type) {
			case "string":
				return { type: "String", nullable: false };
			case "number":
				return { type: "Double", nullable: false };
			case "integer":
				return { type: "Int", nullable: false };
			case "boolean":
				return { type: "Bool", nullable: false };
			case "array":
				return { type: `[${this.type(schema.items ?? {}, scope, singular(prop), path).type}]`, nullable: false };
			case "object": {
				const values = Object.values(schema.patternProperties ?? {});
				if (values.length === 1) return { type: `[String: ${this.type(values[0]!, scope, singular(prop), path).type}]`, nullable: false };
				if (isEmpty(schema)) return { type: this.empty(), nullable: false };
				break;
			}
			case undefined:
				if (Object.keys(schema).filter((k) => k !== "description").length === 0) return { type: "JSONValue", nullable: false };
		}
		throw new Error(`${path}: no Swift type for ${key(schema).slice(0, 160)}`);
	}

	/** A type nested in `scope`, named after `prop` or by swift-names.ts. */
	private nested(schema: Schema, scope: Scope, prop: string, path: string): string {
		const top = swiftNames.topLevel[path];
		if (top) {
			this.used.add(`path:${path}`);
			this.declare(this.module, top, schema, schema.description, path);
			return ref(top);
		}
		let name = swiftNames.nested[path] ?? upperFirst(prop);
		if (name === "Type" && !swiftNames.nested[path]) name = "Kind";
		let parent = scope;
		const dot = name.lastIndexOf(".");
		if (dot > 0) {
			// "SessionSummary.Link": declared in that enclosing type, shared by its fields.
			const owner = name.slice(0, dot);
			name = name.slice(dot + 1);
			for (let s: Scope | undefined = scope; s; s = s.parent) if (s.path === owner) parent = s;
			if (parent.path !== owner) throw new Error(`${path}: ${owner} doesn't enclose it`);
		}
		this.declare(parent, name, schema, schema.description, path);
		return parent === scope ? name : `${parent.path}.${name}`;
	}

	/** `allOf` as one object (Type.Intersect). */
	private merge(schema: Schema): Schema {
		if (!schema.allOf) return schema;
		const parts = schema.allOf.map((s) => this.merge(s));
		if (parts.some((p) => p.type !== "object")) throw new Error(`allOf of non-objects: ${key(schema).slice(0, 120)}`);
		const { allOf: _, ...rest } = schema;
		return { ...rest, type: "object", properties: Object.assign({}, ...parts.map((p) => p.properties)), required: [...new Set(parts.flatMap((p) => p.required ?? []))] };
	}

	/** A Swift type several methods share fits each: sends only what each takes, reads only what each sends. */
	private checkShared(name: string, uses: Use[]): void {
		const [first, ...others] = uses;
		const props = this.merge(first!.schema).properties ?? {};
		const required = new Set(this.merge(first!.schema).required ?? []);
		for (const use of others) {
			const s = this.merge(use.schema);
			const theirs = s.properties ?? {};
			const theirsRequired = new Set(s.required ?? []);
			const problems: string[] = [];
			for (const [p, schema] of Object.entries(props)) {
				if (!(p in theirs)) {
					if (use.direction === "send" || required.has(p)) problems.push(`${p} isn't in ${use.method}`);
					continue;
				}
				if (key(theirs[p]!) !== key(schema)) problems.push(`${p} differs`);
				if (use.direction === "receive" && required.has(p) && !theirsRequired.has(p)) problems.push(`${p} is optional in ${use.method}`);
			}
			if (use.direction === "send") for (const p of theirsRequired) if (!required.has(p)) problems.push(`${use.method} requires ${p}`);
			if (problems.length) throw new Error(`${name} (from ${first!.method}) doesn't fit ${use.method}: ${problems.join("; ")}. Give it its own name in swift-names.ts.`);
		}
	}

	// ── Output ────────────────────────────────────────────────────────────────

	text(): string {
		this.markSent();
		const out: string[] = [HEADER];
		for (const name of [...this.top.keys()].sort()) out.push(this.render(this.top.get(name)!, ""));
		out.push(this.renderTables());
		return out.join("\n").replace(/\n{3,}/g, "\n\n");
	}

	/** Marks the fields of every type the app sends that can be absent or null: only there does the difference matter. */
	private markSent(): void {
		const seen = new Set<Decl>();
		const visit = (type: string, scope: Scope) => {
			for (const d of this.referenced(type, scope)) {
				if (seen.has(d)) continue;
				seen.add(d);
				const fields = d.kind === "struct" ? d.fields : d.kind === "union" ? d.cases.flatMap((c) => c.fields) : [];
				for (const f of fields) {
					if (f.optional && f.nullable) f.tristate = true;
					visit(f.type, d.scope);
				}
				if (d.kind === "struct") for (const e of d.embeds) visit(e.type, d.scope);
				if (d.kind === "union") for (const c of d.cases) if (c.type) visit(c.type, d.scope);
				if (d.kind === "choice") for (const t of d.types) visit(t.type, d.scope);
			}
		};
		for (const [, type] of [...this.tables.params, ...this.tables.reverseResults]) visit(type, this.module);
	}

	/** The declarations a type expression names, looked up from `scope` as Swift would. */
	private referenced(type: string, scope: Scope): Decl[] {
		const out: Decl[] = [];
		for (const m of type.matchAll(/\u0001([A-Za-z0-9_]+)\u0002|([A-Za-z_][A-Za-z0-9_.]*)/g)) {
			if (m[1]) {
				const d = this.top.get(m[1]);
				if (d) out.push(d);
				continue;
			}
			const path = m[2]!.split(".");
			let found: Decl | undefined;
			for (let s: Scope | undefined = scope; s && !found; s = s.parent) found = s.nested.get(path[0]!);
			for (const part of path.slice(1)) found = found?.scope.nested.get(part);
			if (found) out.push(found);
		}
		return out;
	}

	private resolve(type: string, scope: Scope): string {
		return type.replace(/\u0001([A-Za-z0-9_]+)\u0002/g, (_, name: string) => {
			for (let s: Scope | undefined = scope; s && s !== this.module; s = s.parent) if (s.nested.has(name) || s.name === name && s.parent !== this.module) return `PiopioKit.${name}`;
			return name;
		});
	}

	private render(d: Decl, indent: string): string {
		const name = d.scope.name;
		const inner = indent + "    ";
		const nested = [...d.scope.nested.values()].map((n) => this.render(n, inner)).join("");
		switch (d.kind) {
			case "empty":
				return `${indent}public struct Empty: Codable, Sendable, Hashable {\n${inner}public init() {}\n${indent}}\n`;
			case "enum": {
				const cases = d.cases.map((c) => (c.name === c.raw ? ident(c.name) : `${ident(c.name)} = ${JSON.stringify(c.raw)}`)).join(", ");
				// Printed as its value ("needs_you"), as the string it is on the wire.
				return `${doc(d.doc, indent)}${indent}public enum ${name}: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {\n${inner}case ${cases}\n${inner}public var description: String { rawValue }\n${indent}}\n`;
			}
			case "struct":
				return this.renderStruct(d, indent, nested);
			case "union":
				return this.renderUnion(d, indent, nested);
			case "choice":
				return this.renderChoice(d, indent, nested);
		}
	}

	private fieldType(f: Field, scope: Scope): string {
		const t = this.resolve(f.type, scope);
		if (f.tristate) return `Nullable<${t}>?`;
		return f.optional || f.nullable ? `${t}?` : t;
	}

	private renderStruct(d: Extract<Decl, { kind: "struct" }>, indent: string, nested: string): string {
		const inner = indent + "    ";
		const s = d.scope;
		const conforms = ["Codable", "Sendable", "Hashable", ...(d.fields.some((f) => f.json === "id") ? ["Identifiable"] : [])];
		const lines: string[] = [];
		for (const e of d.embeds) lines.push(`${inner}public var ${e.name}: ${this.resolve(e.type, s)}`);
		for (const f of d.fields) lines.push(`${doc(f.doc, inner)}${inner}public var ${f.name}: ${this.fieldType(f, s)}`);
		const params = [...d.embeds.map((e) => `${e.name}: ${this.resolve(e.type, s)}`), ...d.fields.map((f) => `${f.json}: ${this.fieldType(f, s)}${f.optional ? " = nil" : ""}`)].join(", ");
		const assigns = [...d.embeds.map((e) => `self.${e.name} = ${e.name}`), ...d.fields.map((f) => `self.${f.name} = ${f.name}`)].join("; ");
		lines.push(`${inner}public init(${params}) {${assigns ? ` ${assigns} ` : ""}}`);
		const custom = d.consts.length > 0 || d.embeds.length > 0 || d.fields.some((f) => f.nullable && !f.optional);
		if (custom) {
			const keys = [...d.fields.map((f) => f.name), ...d.consts.map((c) => ident(c.json))];
			if (keys.length) lines.push(`${inner}private enum CodingKeys: String, CodingKey { case ${keys.join(", ")} }`);
			if (d.consts.length || d.embeds.length) {
				const decodes = [
					...d.embeds.map((e) => `self.${e.name} = try ${this.resolve(e.type, s)}(from: decoder)`),
					...d.fields.map((f) => `self.${f.name} = try c.${f.optional ? "decodeIfPresent" : "decode"}(${this.decodeType(f, s)}.self, forKey: .${f.name})`),
				];
				lines.push(`${inner}public init(from decoder: Decoder) throws {\n${inner}    ${d.fields.length ? "let c = try decoder.container(keyedBy: CodingKeys.self)\n" + inner + "    " : ""}${decodes.join(`\n${inner}    `)}\n${inner}}`);
			}
			const encodes = [
				...d.embeds.map((e) => `try self.${e.name}.encode(to: encoder)`),
				...(keys.length ? ["var c = encoder.container(keyedBy: CodingKeys.self)"] : []),
				...d.consts.map((c) => `try c.encode(${JSON.stringify(c.value)}, forKey: .${ident(c.json)})`),
				...d.fields.map((f) => `try c.${f.optional ? "encodeIfPresent" : "encode"}(self.${f.name}, forKey: .${f.name})`),
			];
			lines.push(`${inner}public func encode(to encoder: Encoder) throws {\n${inner}    ${encodes.join(`\n${inner}    `)}\n${inner}}`);
		}
		return `${doc(d.doc, indent)}${indent}public struct ${s.name}: ${conforms.join(", ")} {\n${nested}${lines.join("\n")}\n${indent}}\n`;
	}

	/** The type a field decodes as, with `decodeIfPresent` when it's optional (where null reads as absent). */
	private decodeType(f: Field, scope: Scope): string {
		const t = this.resolve(f.type, scope);
		if (f.tristate) return `Nullable<${t}>`;
		return f.nullable && !f.optional ? `${t}?` : t;
	}

	private renderUnion(d: Extract<Decl, { kind: "union" }>, indent: string, nested: string): string {
		const inner = indent + "    ";
		const s = d.scope;
		const assoc = (c: UnionCase) => {
			if (c.type) return `(${this.resolve(c.type, s)})`;
			if (c.fields.length === 0) return "";
			if (c.fields.length === 1) return `(${this.fieldType(c.fields[0]!, s)})`;
			return `(${c.fields.map((f) => `${f.json}: ${this.fieldType(f, s)}${f.optional ? " = nil" : ""}`).join(", ")})`;
		};
		const lines = d.cases.map((c) => `${inner}case ${ident(c.name)}${assoc(c)}`);
		if (d.open) lines.push(`${inner}/// A ${d.tag} this app doesn't know (a newer engine's).\n${inner}case unknown(String)`);
		const keys = new Set([d.tag, ...d.cases.flatMap((c) => c.fields.map((f) => f.json))]);
		lines.push(`${inner}private enum CodingKeys: String, CodingKey { case ${[...keys].map(ident).join(", ")} }`);
		const decodeField = (f: Field) => `try c.${f.optional ? "decodeIfPresent" : "decode"}(${this.decodeType(f, s)}.self, forKey: .${f.name})`;
		const decodes = d.cases.map((c) => {
			let value = `.${ident(c.name)}`;
			if (c.type) value += `(try ${this.resolve(c.type, s)}(from: decoder))`;
			else if (c.fields.length === 1) value += `(${decodeField(c.fields[0]!)})`;
			else if (c.fields.length) value += `(${c.fields.map((f) => `${f.json}: ${decodeField(f)}`).join(", ")})`;
			return `${inner}    case ${JSON.stringify(c.raw)}: self = ${value}`;
		});
		const fallback = d.open ? `self = .unknown(tag)` : `throw DecodingError.dataCorruptedError(forKey: .${d.tag}, in: c, debugDescription: "Unknown ${d.tag} \\(tag)")`;
		lines.push(`${inner}public init(from decoder: Decoder) throws {\n${inner}    let c = try decoder.container(keyedBy: CodingKeys.self)\n${inner}    let tag = try c.decode(String.self, forKey: .${d.tag})\n${inner}    switch tag {\n${decodes.join("\n")}\n${inner}    default: ${fallback}\n${inner}    }\n${inner}}`);
		const encodes = d.cases.map((c) => {
			const bind = c.type ? "(let v)" : c.fields.length ? `(${c.fields.map((f) => `let ${f.name}`).join(", ")})` : "";
			const body = c.type
				? `try v.encode(to: encoder)`
				: [`var c = encoder.container(keyedBy: CodingKeys.self)`, `try c.encode(${JSON.stringify(c.raw)}, forKey: .${d.tag})`, ...c.fields.map((f) => `try c.${f.optional ? "encodeIfPresent" : "encode"}(${f.name}, forKey: .${f.name})`)].join("; ");
			return `${inner}    case .${ident(c.name)}${bind}: ${body}`;
		});
		if (d.open) encodes.push(`${inner}    case .unknown(let tag): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(tag, forKey: .${d.tag})`);
		lines.push(`${inner}public func encode(to encoder: Encoder) throws {\n${inner}    switch self {\n${encodes.join("\n")}\n${inner}    }\n${inner}}`);
		return `${doc(d.doc, indent)}${indent}public enum ${s.name}: Codable, Sendable, Hashable {\n${nested}${lines.join("\n")}\n${indent}}\n`;
	}

	private renderChoice(d: Extract<Decl, { kind: "choice" }>, indent: string, nested: string): string {
		const inner = indent + "    ";
		const s = d.scope;
		const lines = [...d.literals.map((l) => `${inner}case ${ident(l.name)}`), ...d.types.map((t) => `${inner}case ${ident(t.name)}(${this.resolve(t.type, s)})`)];
		const literalDecodes = d.literals.map((l) => `${inner}        case ${JSON.stringify(l.raw)}: self = .${ident(l.name)}; return`).join("\n");
		const typeDecodes = d.types.map((t, i) => (i === d.types.length - 1 ? `${inner}    self = .${ident(t.name)}(try ${this.resolve(t.type, s)}(from: decoder))` : `${inner}    if let v = try? ${this.resolve(t.type, s)}(from: decoder) { self = .${ident(t.name)}(v); return }`));
		lines.push(
			`${inner}public init(from decoder: Decoder) throws {\n${inner}    if let text = try? decoder.singleValueContainer().decode(String.self) {\n${inner}        switch text {\n${literalDecodes}\n${inner}        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown value \\(text)"))\n${inner}        }\n${inner}    }\n${typeDecodes.join("\n")}\n${inner}}`,
		);
		const encodes = [...d.literals.map((l) => `${inner}    case .${ident(l.name)}: var c = encoder.singleValueContainer(); try c.encode(${JSON.stringify(l.raw)})`), ...d.types.map((t) => `${inner}    case .${ident(t.name)}(let v): try v.encode(to: encoder)`)];
		lines.push(`${inner}public func encode(to encoder: Encoder) throws {\n${inner}    switch self {\n${encodes.join("\n")}\n${inner}    }\n${inner}}`);
		return `${doc(d.doc, indent)}${indent}public enum ${s.name}: Codable, Sendable, Hashable {\n${nested}${lines.join("\n")}\n${indent}}\n`;
	}

	private renderTables(): string {
		const table = (name: string, what: string, rows: [string, string][]) =>
			`    /// ${what}\n    public static let ${name}: [String: any (Codable & Sendable).Type] = [\n${rows
				.sort(([a], [b]) => (a < b ? -1 : 1))
				.map(([m, t]) => `        ${JSON.stringify(m)}: ${this.resolve(t, this.module)}.self,`)
				.join("\n")}\n    ]`;
		return `/// Every method's params and result type, and every notification's, by name: what the app sends and reads.
public enum ProtocolTypes {
${table("definitions", "The schema's named definitions (src/schema.ts).", this.tables.definitions)}
${table("params", "What each method takes.", this.tables.params)}
${table("results", "What each method answers.", this.tables.results)}
${table("notifications", "What each notification carries.", this.tables.notifications)}
${table("reverseParams", "What each request from the engine to the app carries.", this.tables.reverseParams)}
${table("reverseResults", "What the app answers each request from the engine with.", this.tables.reverseResults)}
}
`;
	}
}

const HEADER = `// Generated from the engine's protocol (packages/protocol/src/index.ts) by packages/protocol/src/swift.ts.
// Don't edit: run \`corepack pnpm schema\` from the repository root. Helpers go in Protocol.swift.
// See docs/spec/03-engine-protocol.md, "Swift types".

import Foundation

/// A field that may be absent, null or a value: absent leaves it as it is, null clears it.
public enum Nullable<Wrapped: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    case null
    case value(Wrapped)
    public init(_ value: Wrapped?) { self = value.map(Nullable.value) ?? .null }
    public var value: Wrapped? { if case .value(let v) = self { v } else { nil } }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = c.decodeNil() ? .null : .value(try c.decode(Wrapped.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .value(let v): try c.encode(v) }
    }
}
`;

function isEmpty(s: Schema): boolean {
	return s.type === "object" && Object.keys(s.properties ?? {}).length === 0 && !s.patternProperties;
}
function isPrimitive(s: Schema): boolean {
	return !s.anyOf && s.type !== "object" && s.type !== "array";
}
/** The strings of a union of string literals (or a lone literal). */
function stringLiterals(s: Schema): string[] | undefined {
	if (s.anyOf && s.anyOf.length > 0 && s.anyOf.every((b) => typeof b.const === "string")) return s.anyOf.map((b) => b.const as string);
	if (typeof s.const === "string") return [s.const];
	return undefined;
}
/** The property every branch has as a distinct constant ("type", "kind"). */
function tagOf(branches: Schema[]): string | undefined {
	if (!branches.every((b) => b.type === "object")) return undefined;
	const candidates = Object.keys(branches[0]!.properties ?? {}).filter((p) => branches.every((b) => b.properties?.[p] && "const" in b.properties[p]! && b.required?.includes(p)));
	return candidates.find((p) => new Set(branches.map((b) => b.properties![p]!.const)).size === branches.length);
}

/** Where the generated Swift goes: the Mac app's PiopioKit, beside the hand-written Protocol.swift. */
export const SWIFT_FILE = new URL("../../../apps/mac/Sources/PiopioKit/Protocol.generated.swift", import.meta.url);

export function protocolSwiftText(): string {
	const g = new SwiftGenerator(JSON.parse(JSON.stringify(protocolSchema().definitions)) as Record<string, Schema>);
	g.run();
	return g.text();
}
