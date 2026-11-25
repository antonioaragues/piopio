/**
 * Apps whose tools come from their own MCP server (docs/spec/12 §4), such as Linear: sign-in through the server's
 * OAuth (pi-mcp: discovery, dynamic client registration, PKCE, refresh), the server's tools kept with their kind
 * (reading, changing, deleting) so Settings can show them and changes ask first, and one connection per account for
 * the calls. The OAuth state (client and tokens) lives in the Keychain, as `connector.<app>.<account>`.
 */
import { McpClient, type McpFetch, StreamableHttpTransport, limitMcpContent, normalizeMcpInputSchema, toLlmContent, type Tool } from "@earendil-works/pi-mcp";
import {
	completeMcpSignIn,
	createMcpAuthProvider,
	listenForLoopbackSignIn,
	McpOAuthAuthorizationRequiredError,
	type McpOAuthServerStore,
	type McpOAuthState,
	startMcpSignIn,
	waitForLoopbackSignIn,
} from "@earendil-works/pi-mcp/oauth";
import type { ProviderAuthEvent } from "@piopio/protocol";
import type { Access, CapabilityGroup } from "./permissions.js";
import type { McpCall, McpConnector, McpToolInfo } from "./types.js";

const CLIENT = { name: "Piopio", version: "1.0.0" };
const LOGIN_TIMEOUT_MS = 5 * 60_000;

/** Where an account's OAuth state is kept: memory while signing in, then the Keychain. */
export type StateIO = { load(): Promise<McpOAuthState | undefined>; save(state: McpOAuthState): Promise<void> };

/** pi-mcp's store with an in-process refresh lock (one engine per Mac uses these tokens). */
export class LockedStore implements McpOAuthServerStore {
	private chain: Promise<unknown> = Promise.resolve();
	constructor(private readonly io: StateIO) {}
	load() {
		return this.io.load();
	}
	save(state: McpOAuthState) {
		return this.io.save(state);
	}
	withRefreshLock<T>(fn: () => Promise<T>): Promise<T> {
		const run = this.chain.then(fn, fn);
		this.chain = run.catch(() => undefined);
		return run;
	}
}

export const memoryIO = (): StateIO & { state?: McpOAuthState } => {
	const io: StateIO & { state?: McpOAuthState } = {
		load: async () => io.state,
		save: async (state) => {
			io.state = state;
		},
	};
	return io;
};

const DELETES = /^(delete|remove|archive|retire|destroy|purge|trash|merge)$/;
const CHANGES = /^(create|save|update|add|set|mark|share|unshare|restore|resolve|submit|prepare|upload|assign|move|edit|post|send|comment|link|unlink|close|reopen)$/;
const READS = /^(list|get|search|find|read|fetch|query|show|view|lookup|whoami|extract|describe|count)$/;

/**
 * What a server's tool does: what the app says, then a clear verb in its name, then the server's hints, unsure meaning
 * it changes things. Names come before hints because servers mark upserts destructive (Linear's save_issue creates or
 * updates an issue, and is marked destructive because it can overwrite).
 */
export function accessOf(tool: Pick<Tool, "name" | "annotations">, overrides?: Record<string, Access>): Access {
	const set = overrides?.[tool.name];
	if (set) return set;
	// The first word: list_issues, notion-search (after the app's own prefix), getJiraIssue.
	const verb = (tool.name.match(/^[A-Za-z][a-z]*/)?.[0] ?? "").toLowerCase();
	if (DELETES.test(verb)) return "destructive";
	if (tool.annotations?.readOnlyHint === true) return "read";
	if (CHANGES.test(verb)) return "write";
	if (tool.annotations?.destructiveHint === true) return "destructive";
	if (READS.test(verb)) return "read";
	return "write";
}

/** A tool's name without the app's own prefix (Notion's notion-search is "search"). */
const local = (def: McpConnector, name: string) => name.replace(new RegExp(`^${def.mcp.prefix}[-_]`, "i"), "");

export function toolInfos(def: McpConnector, tools: Tool[]): McpToolInfo[] {
	return tools.map((t) => ({
		name: t.name,
		...(t.title ?? t.annotations?.title ? { title: t.title ?? t.annotations?.title } : {}),
		description: t.description ?? t.name,
		inputSchema: normalizeMcpInputSchema(t.inputSchema as Record<string, unknown>),
		access: def.mcp.access?.[t.name] ?? accessOf({ ...t, name: local(def, t.name) }),
	}));
}

/** The name a conversation sees: `<prefix>_<tool>`, as providers allow (64 characters of [A-Za-z0-9_-]). */
export const modelName = (def: McpConnector, tool: string) => `${def.mcp.prefix}_${local(def, tool)}`.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 64);

/** Apps with more tools than this, and no core list, offer them all through tool search. */
export const DIRECT_LIMIT = 12;

/**
 * Which of an app's tools are offered up front (`direct`) and which wait for tool search (`deferred`): the app's core
 * list, else all of them when there are few, else none.
 */
export function splitTools(def: McpConnector, tools: McpToolInfo[]): { direct: McpToolInfo[]; deferred: McpToolInfo[] } {
	const core = def.mcp.core;
	if (!core) return tools.length <= DIRECT_LIMIT ? { direct: tools, deferred: [] } : { direct: [], deferred: tools };
	return { direct: tools.filter((t) => core.includes(t.name)), deferred: tools.filter((t) => !core.includes(t.name)) };
}

/** Settings' groups for an MCP app: its reading, changing and deleting tools (a kind with no tools isn't shown once connected). */
export function mcpGroups(def: McpConnector, tools: McpToolInfo[] | undefined): CapabilityGroup[] {
	const kinds: { access: Access; key: string; label: string }[] = [
		{ access: "read", key: "read", label: def.mcp.labels.read },
		{ access: "write", key: "write", label: def.mcp.labels.write },
		{ access: "destructive", key: "delete", label: def.mcp.labels.destructive },
	];
	return kinds
		.map((k) => ({ id: `${def.id}.${k.key}`, capability: "mcp" as const, label: k.label, access: k.access, tools: (tools ?? []).filter((t) => t.access === k.access).map((t) => modelName(def, t.name)) }))
		.filter((g) => !tools || g.tools.length > 0);
}

/**
 * Who signed in, from one of the app's own tools ("whoami", "get_me"): an id and an email, login or name found in its
 * JSON answer, or an email in its text. Undefined when the app has no such tool or says nothing usable.
 */
export function identifyWith(tool: string, args: Record<string, unknown> = {}): NonNullable<McpConnector["mcp"]["identify"]> {
	return async (call, tools) => {
		if (!tools.some((t) => t.name === tool)) return undefined;
		const answer = await call(tool, args).catch(() => undefined);
		if (!answer || answer.isError) return undefined;
		const found: Record<string, string> = {};
		const walk = (value: unknown, depth: number): void => {
			if (!value || typeof value !== "object" || depth > 3) return;
			for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
				const key = k.toLowerCase().replace(/[_-]/g, "");
				if ((typeof v === "string" || typeof v === "number") && String(v).trim() && !(key in found)) found[key] = String(v).trim();
				else walk(v, depth + 1);
			}
		};
		try {
			walk(JSON.parse(answer.text), 0);
		} catch {
			// a sentence, such as Sentry's "You are authenticated as …"
		}
		const email = found.email ?? found.mail ?? answer.text.match(/[\w.+-]+@[\w-]+(\.[\w-]+)+/)?.[0];
		const label = email ?? found.login ?? found.username ?? found.name ?? found.displayname;
		const id = found.accountid ?? found.userid ?? found.id ?? found.login ?? email;
		return id && label ? { id, label } : undefined;
	};
}

/** A readable title for an approval: "Create issue in Linear: “Fix the login”". */
export function callTitle(def: McpConnector, tool: McpToolInfo, args: Record<string, unknown>): string {
	const action = tool.title ?? tool.name.replace(/[_-]+/g, " ").replace(/^./, (c) => c.toUpperCase());
	const what = ["title", "name", "body", "query", "id"].map((k) => args[k]).find((v) => typeof v === "string" && v.trim()) as string | undefined;
	return `${action} in ${def.name}${what ? `: “${what.length > 80 ? `${what.slice(0, 79)}…` : what}”` : ""}`;
}

/** Signs in to an MCP server through the browser; resolves with the OAuth state to keep. */
export async function signInMcp(def: McpConnector, url: string, signal: AbortSignal, emit: (e: ProviderAuthEvent) => void, page: (title: string, text: string) => string): Promise<McpOAuthState> {
	const io = memoryIO();
	const store = new LockedStore(io);
	const settings = { ...(def.mcp.scope ? { scope: def.mcp.scope } : {}), clientRegistration: "dcr" as const };
	const loop = await listenForLoopbackSignIn({
		serverUrl: url,
		store,
		settings,
		renderPage: (p) => (p.ok ? page("Connected", "You can close this tab and go back to Piopio.") : page("Not connected", `${p.message} You can close this tab.`)),
	});
	try {
		const options = { serverUrl: url, store, settings, clientName: CLIENT.name, redirectUrl: loop.redirectUrl, signal };
		const started = await startMcpSignIn(options);
		if (started.kind === "redirect") {
			emit({ type: "auth_url", url: started.authorizationUrl, instructions: `Sign in to ${def.name} in your browser. This updates when you're done.` });
			const timeout = AbortSignal.timeout(LOGIN_TIMEOUT_MS);
			const response = await waitForLoopbackSignIn({ callback: loop.callback, authorization: started, signal: AbortSignal.any([signal, timeout]) }).catch((error: unknown) => {
				throw timeout.aborted ? new Error("Sign-in timed out. Try again.") : error;
			});
			emit({ type: "progress", message: "Finishing sign-in…" });
			await completeMcpSignIn({ ...options, authorization: started, response });
		}
		if (!io.state?.tokens) throw new Error(`${def.name} didn't complete the sign-in.`);
		return io.state;
	} finally {
		loop.callback.close();
	}
}

/** The user has to sign in again (the server refused the stored tokens). */
export class McpNeedsSignIn extends Error {}

/** One account's connection: opened on first use, reopened after it drops. */
/** How an account signs its requests: the server's OAuth (state in `io`), or a token Piopio already has (GitHub's). */
export type McpAuth = { io: StateIO } | { token: () => Promise<string | undefined>; help: string };

export class McpAccount {
	private client?: Promise<McpClient>;
	private readonly store?: LockedStore;

	constructor(
		private readonly def: McpConnector,
		private readonly url: string,
		private readonly auth: McpAuth,
		private readonly fetchImpl?: McpFetch,
	) {
		if ("io" in auth) this.store = new LockedStore(auth.io);
	}

	private connect(): Promise<McpClient> {
		this.client ??= (async () => {
			const client = new McpClient({ ...CLIENT, requestTimeoutMs: 60_000 });
			const store = this.store;
			const authProvider = store
				? createMcpAuthProvider({
						serverUrl: this.url,
						store,
						settings: () => ({ ...(this.def.mcp.scope ? { scope: this.def.mcp.scope } : {}), clientRegistration: "dcr" }),
						clientName: CLIENT.name,
						onChallenge: () => {},
					})
				: undefined;
			let headers: Record<string, string> | undefined;
			if ("token" in this.auth) {
				const token = await this.auth.token();
				if (!token) throw new McpNeedsSignIn(this.auth.help);
				headers = { authorization: `Bearer ${token}` };
			}
			client.onClose(() => {
				this.client = undefined;
			});
			try {
				await client.connect(new StreamableHttpTransport({ url: this.url, openGetStream: false, ...(authProvider ? { authProvider } : {}), ...(headers ? { headers } : {}), ...(this.fetchImpl ? { fetch: this.fetchImpl } : {}) }));
			} catch (error) {
				this.client = undefined;
				throw this.explain(error);
			}
			return client;
		})();
		return this.client;
	}

	private explain(error: unknown): Error {
		if (error instanceof McpNeedsSignIn) return error;
		if (error instanceof McpOAuthAuthorizationRequiredError || /401|invalid_token|unauthori[sz]ed/i.test(String((error as Error)?.message)))
			return new McpNeedsSignIn("token" in this.auth ? this.auth.help : `${this.def.name} needs you to sign in again.`);
		return error instanceof Error ? error : new Error(String(error));
	}

	/**
	 * After a failure the client goes, so the next request connects again: a session the server dropped (a 404 for its
	 * id), a transport that died across a sleep, or a token that was renewed would otherwise keep failing until a restart.
	 */
	private reset(): void {
		const old = this.client;
		this.client = undefined;
		void old?.then((c) => c.close()).catch(() => undefined);
	}

	async tools(): Promise<Tool[]> {
		try {
			return await (await this.connect()).listTools();
		} catch (first) {
			if (this.explain(first) instanceof McpNeedsSignIn) throw this.explain(first);
			// Listing has no effects: once more, on a new connection.
			this.reset();
			try {
				return await (await this.connect()).listTools();
			} catch (error) {
				this.reset();
				throw this.explain(error);
			}
		}
	}

	readonly call: McpCall = async (tool, args) => {
		let result;
		try {
			result = await (await this.connect()).callTool(tool, args);
		} catch (error) {
			// Not again by itself: the tool may have done its work before the answer was lost.
			this.reset();
			throw this.explain(error);
		}
		// pi-mcp turns the server's answer into what a model takes (text and images) and bounds it. Images go on as
		// images: the model sees them where it can, and pi shows a placeholder to one that can't.
		const content = await limitMcpContent(toLlmContent(result));
		const text = content.content
			.flatMap((c) => (c.type === "text" ? [c.text] : []))
			.join("\n")
			.trim();
		const images = content.content.flatMap((c) => (c.type === "image" ? [{ data: c.data, mimeType: c.mimeType }] : []));
		return { text: text || (result.isError ? "The tool failed without saying why." : images.length ? "" : "Done."), isError: result.isError === true, ...(images.length ? { images } : {}) };
	};

	async close(): Promise<void> {
		const client = this.client;
		this.client = undefined;
		await client?.then((c) => c.close()).catch(() => undefined);
	}
}
