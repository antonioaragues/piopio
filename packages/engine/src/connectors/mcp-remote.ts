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
	const verb = tool.name.toLowerCase().split(/[_\-.]/)[0] ?? "";
	if (DELETES.test(verb)) return "destructive";
	if (tool.annotations?.readOnlyHint === true) return "read";
	if (CHANGES.test(verb)) return "write";
	if (tool.annotations?.destructiveHint === true) return "destructive";
	if (READS.test(verb)) return "read";
	return "write";
}

export function toolInfos(def: McpConnector, tools: Tool[]): McpToolInfo[] {
	return tools.map((t) => ({
		name: t.name,
		...(t.title ?? t.annotations?.title ? { title: t.title ?? t.annotations?.title } : {}),
		description: t.description ?? t.name,
		inputSchema: normalizeMcpInputSchema(t.inputSchema as Record<string, unknown>),
		access: accessOf(t, def.mcp.access),
	}));
}

/** The name a conversation sees: `<prefix>_<tool>`, as providers allow (64 characters of [A-Za-z0-9_-]). */
export const modelName = (def: McpConnector, tool: string) => `${def.mcp.prefix}_${tool}`.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 64);

/** The one tool that reaches an app's other tools by name (Linear has about 70; most conversations need a dozen). */
export const moreName = (def: McpConnector) => `${def.mcp.prefix}_more`;

/** The tools offered directly; the rest go through `<prefix>_more`. Without a core list, all of them. */
export function splitTools(def: McpConnector, tools: McpToolInfo[]): { core: McpToolInfo[]; rest: McpToolInfo[] } {
	const core = def.mcp.core;
	if (!core) return { core: tools, rest: [] };
	return { core: tools.filter((t) => core.includes(t.name)), rest: tools.filter((t) => !core.includes(t.name)) };
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
export class McpAccount {
	private client?: Promise<McpClient>;
	readonly store: LockedStore;

	constructor(
		private readonly def: McpConnector,
		private readonly url: string,
		io: StateIO,
		private readonly fetchImpl?: McpFetch,
	) {
		this.store = new LockedStore(io);
	}

	private connect(): Promise<McpClient> {
		this.client ??= (async () => {
			const client = new McpClient({ ...CLIENT, requestTimeoutMs: 60_000 });
			const authProvider = createMcpAuthProvider({
				serverUrl: this.url,
				store: this.store,
				settings: () => ({ ...(this.def.mcp.scope ? { scope: this.def.mcp.scope } : {}), clientRegistration: "dcr" }),
				clientName: CLIENT.name,
				onChallenge: () => {},
			});
			client.onClose(() => {
				this.client = undefined;
			});
			try {
				await client.connect(new StreamableHttpTransport({ url: this.url, authProvider, openGetStream: false, ...(this.fetchImpl ? { fetch: this.fetchImpl } : {}) }));
			} catch (error) {
				this.client = undefined;
				throw this.explain(error);
			}
			return client;
		})();
		return this.client;
	}

	private explain(error: unknown): Error {
		if (error instanceof McpOAuthAuthorizationRequiredError || /401|invalid_token|unauthori[sz]ed/i.test(String((error as Error)?.message))) return new McpNeedsSignIn(`${this.def.name} needs you to sign in again.`);
		return error instanceof Error ? error : new Error(String(error));
	}

	async tools(): Promise<Tool[]> {
		try {
			return await (await this.connect()).listTools();
		} catch (error) {
			throw this.explain(error);
		}
	}

	readonly call: McpCall = async (tool, args) => {
		let result;
		try {
			result = await (await this.connect()).callTool(tool, args);
		} catch (error) {
			throw this.explain(error);
		}
		const content = await limitMcpContent(toLlmContent(result));
		const text = content.content
			.map((c) => (c.type === "text" ? c.text : "[image]"))
			.join("\n")
			.trim();
		return { text: text || (result.isError ? "The tool failed without saying why." : "Done."), isError: result.isError === true };
	};

	async close(): Promise<void> {
		const client = this.client;
		this.client = undefined;
		await client?.then((c) => c.close()).catch(() => undefined);
	}
}
