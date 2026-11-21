/**
 * Connected apps (docs/spec/12-connectors): which connectors exist, the accounts you signed in to, their settings,
 * and an authorized fetch per account. Sign-in is OAuth 2.0 with PKCE through the browser and a loopback redirect
 * (RFC 8252); tokens live in the app's Keychain (`connector.<connector>.<account>`), refreshed when they expire.
 * The list of accounts and the settings (no secrets) live in `connectors.json`.
 */
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { ProviderAuthEvent } from "@piopio/protocol";
import type { SecretBroker } from "../secrets.js";
import type { McpOAuthState } from "@earendil-works/pi-mcp/oauth";
import { googleCalendar } from "./google-calendar.js";
import { linear } from "./linear.js";
import { McpAccount, McpNeedsSignIn, mcpGroups, memoryIO, signInMcp, type StateIO, toolInfos } from "./mcp-remote.js";
import { outlook } from "./outlook.js";
import { CAPABILITIES, type CapabilityGroup, defaultPermission, groupOf, type Permission } from "./permissions.js";
import { type ApiConnector, type AuthorizedFetch, type Calendar, type CalendarEntry, type ConnectorDefinition, type ConnectorEndpoints, isMcp, type Mailbox, type McpCall, type McpConnector, type McpToolInfo, type Tokens } from "./types.js";

export type Account = { id: string; connector: string; label: string; addedAt: string };
/**
 * Per app: offered in chats, what each tool may do (`permissions`, by tool name; `dontAsk` is C1's form of "runs"),
 * and a developer's own OAuth client.
 */
export type ConnectorSettings = { chats: boolean; dontAsk: string[]; permissions?: Record<string, Permission>; clientId?: string };
/** Per account: calendars turned on or off in Settings (absent: what the app itself shows). */
type State = {
	accounts: Account[];
	settings: Record<string, ConnectorSettings>;
	calendars?: Record<string, Record<string, boolean>>;
	/** MCP apps: the tools their server offered last time, so conversations get them without waiting for the server. */
	tools?: Record<string, McpToolInfo[]>;
};

/** An MCP app's account as conversations use it: its tools and how to call them. */
export type McpUse = { account: Account; def: McpConnector; tools: McpToolInfo[]; call: McpCall };

/** OAuth clients Piopio ships with (docs/spec/12 §2): empty until our Google and Microsoft apps are registered. */
const BUILT_IN_CLIENTS: Record<string, string> = {};

const LOGIN_TIMEOUT_MS = 5 * 60_000;

type Emit = (loginId: string, connector: string, event: ProviderAuthEvent) => void;
type Login = { connector: string; abort: AbortController };

export class ConnectorHub {
	readonly definitions: ConnectorDefinition[];
	private state: State = { accounts: [], settings: {} };
	private readonly logins = new Map<string, Login>();
	private readonly problems = new Map<string, string>();
	private readonly mcp = new Map<string, McpAccount>();
	/** Set by the server: connected apps changed (accounts, settings, needs attention). */
	onChange?: () => void;

	constructor(
		private readonly secrets: SecretBroker,
		private readonly options: { home?: string; endpoints?: ConnectorEndpoints; fetchImpl?: typeof fetch; emit?: Emit } = {},
	) {
		this.definitions = [googleCalendar, outlook, linear].map((d): ConnectorDefinition => {
			const o = options.endpoints?.[d.id];
			if (!o) return d;
			if (isMcp(d)) return o.mcpUrl ? { ...d, mcp: { ...d.mcp, url: o.mcpUrl } } : d;
			return { ...d, apiBase: o.apiBase ?? d.apiBase, oauth: { ...d.oauth, ...(o.authorizeUrl ? { authorizeUrl: o.authorizeUrl } : {}), ...(o.tokenUrl ? { tokenUrl: o.tokenUrl } : {}) } };
		});
		const path = this.path;
		if (path && existsSync(path)) {
			try {
				this.state = { accounts: [], settings: {}, ...(JSON.parse(readFileSync(path, "utf8")) as Partial<State>) };
			} catch {
				// a damaged file only loses the list; tokens stay in the Keychain
			}
		}
	}

	private get path(): string | undefined {
		return this.options.home ? `${this.options.home}/connectors.json` : undefined;
	}

	private save(): void {
		if (this.path) writeFileSync(this.path, `${JSON.stringify(this.state, null, "\t")}\n`, { mode: 0o600 });
		this.onChange?.();
	}

	private get fetchImpl(): typeof fetch {
		return this.options.fetchImpl ?? fetch;
	}

	definition(id: string): ConnectorDefinition | undefined {
		return this.definitions.find((d) => d.id === id);
	}

	settings(id: string): ConnectorSettings {
		return { chats: true, dontAsk: [], ...this.state.settings[id] };
	}

	accounts(connector?: string): Account[] {
		return this.state.accounts.filter((a) => !connector || a.connector === connector);
	}

	problem(accountId: string): string | undefined {
		return this.problems.get(accountId);
	}

	connecting(connector: string): boolean {
		return [...this.logins.values()].some((l) => l.connector === connector);
	}

	/** The OAuth client: yours from settings or the environment, else Piopio's own. */
	clientId(connector: string): string | undefined {
		const env = process.env[`PIOPIO_${connector.toUpperCase().replaceAll("-", "_")}_CLIENT_ID`];
		return this.state.settings[connector]?.clientId || env || BUILT_IN_CLIENTS[connector];
	}

	private async clientSecret(connector: string): Promise<string | undefined> {
		const env = process.env[`PIOPIO_${connector.toUpperCase().replaceAll("-", "_")}_CLIENT_SECRET`];
		return env ?? (await this.secrets.get(`connector.${connector}.clientSecret`, "Sign in to the app")) ?? undefined;
	}

	async hasClientSecret(connector: string): Promise<boolean> {
		return Boolean(await this.clientSecret(connector).catch(() => undefined));
	}

	/** What a tool may do with this app: set in Settings, else C1's "Don't ask again", else the safe default. */
	permission(connector: string, tool: string): Permission {
		const s = this.settings(connector);
		const group = this.groupFor(connector, tool);
		// MCP apps keep one setting per kind of tool, so tools the server adds later follow it.
		const set = (group && this.isMcpApp(connector) ? s.permissions?.[group.id] : undefined) ?? s.permissions?.[tool];
		if (set) return set;
		if (s.dontAsk.includes(tool) && group?.access === "write") return "runs";
		return defaultPermission(group?.access ?? "write");
	}

	async configure(connector: string, patch: { chats?: boolean; dontAsk?: string[]; permissions?: Record<string, Permission>; clientId?: string; clientSecret?: string }): Promise<void> {
		if (!this.definition(connector)) throw new Error(`No connector ${connector}`);
		const current = this.settings(connector);
		const permissions: Record<string, Permission> = { ...current.permissions };
		for (const [key, p] of Object.entries(patch.permissions ?? {})) {
			const group = this.groupFor(connector, key);
			permissions[group && this.isMcpApp(connector) ? group.id : key] = p;
		}
		for (const [key, p] of Object.entries(permissions)) {
			const access = this.groupFor(connector, key)?.access;
			if (!access) delete permissions[key];
			else if (p === "runs" && (access === "send" || access === "destructive")) permissions[key] = "ask";
		}
		this.state.settings[connector] = {
			chats: patch.chats ?? current.chats,
			dontAsk: patch.dontAsk ?? current.dontAsk,
			...(Object.keys(permissions).length ? { permissions } : {}),
			...((patch.clientId ?? current.clientId) ? { clientId: (patch.clientId ?? current.clientId)!.trim() } : {}),
		};
		if (patch.clientSecret !== undefined) {
			if (patch.clientSecret.trim()) await this.secrets.set(`connector.${connector}.clientSecret`, patch.clientSecret.trim());
			else await this.secrets.delete(`connector.${connector}.clientSecret`);
		}
		this.save();
	}

	/** Lets a write action run without asking from now on (an approval's "Don't ask again"). */
	/** "Don't ask again" on an approval: the tool's whole capability runs from now on. */
	async allow(connector: string, tool: string): Promise<void> {
		const tools = this.groupFor(connector, tool)?.tools ?? [tool];
		if (tools.some((t) => this.permission(connector, t) !== "runs")) await this.configure(connector, { permissions: Object.fromEntries(tools.map((t) => [t, "runs" as const])) });
	}

	private isMcpApp(connector: string): boolean {
		const def = this.definition(connector);
		return Boolean(def && isMcp(def));
	}

	/** An app's groups of tools: the fixed calendar and mail ones, or an MCP app's reading, changing and deleting tools. */
	private groups(connector: string): CapabilityGroup[] {
		const def = this.definition(connector);
		if (!def) return [];
		if (isMcp(def)) return mcpGroups(def, this.state.tools?.[connector]);
		const has = new Set([...(def.calendar ? ["calendar"] : []), ...(def.mailbox ? ["mail"] : [])]);
		return CAPABILITIES.filter((g) => has.has(g.capability));
	}

	/** The group a tool (or, for MCP apps, a group id) belongs to. */
	groupFor(connector: string, tool: string): CapabilityGroup | undefined {
		const def = this.definition(connector);
		if (def && isMcp(def)) return mcpGroups(def, this.state.tools?.[connector]).find((g) => g.id === tool || g.tools.includes(tool)) ?? mcpGroups(def, undefined).find((g) => g.id === tool);
		return groupOf(tool);
	}

	/** The capabilities an app offers, as Settings shows them: each with its tools and permission. */
	capabilities(connector: string) {
		return this.groups(connector).map((g) => ({ ...g, permission: g.tools[0] ? this.permission(connector, g.tools[0]) : (this.settings(connector).permissions?.[g.id] ?? defaultPermission(g.access)) }));
	}

	// ── Calendars (Settings › Connectors, the calendars card) ──

	/** An account's calendars, each on or off for Piopio. */
	async calendarList(accountId: string): Promise<(CalendarEntry & { enabled: boolean })[]> {
		const account = this.state.accounts.find((a) => a.id === accountId);
		const def = account && this.definition(account.connector);
		if (!account || !def || isMcp(def) || !def.calendar) return [];
		const chosen = this.state.calendars?.[accountId] ?? {};
		return (await def.calendar(this.authorized(account)).calendars()).map((c) => ({ ...c, enabled: chosen[c.id] ?? c.shown }));
	}

	setCalendar(accountId: string, calendarId: string, enabled: boolean): void {
		this.state.calendars ??= {};
		this.state.calendars[accountId] = { ...this.state.calendars[accountId], [calendarId]: enabled };
		this.save();
	}

	// ── Sign-in ──

	/** Starts signing in; steps go out as `connectors.auth` (the browser page, then done or failed). */
	connect(connector: string): string {
		const def = this.definition(connector);
		if (!def) throw new Error(`No connector ${connector}`);
		const clientId = isMcp(def) ? "" : this.clientId(connector);
		if (!isMcp(def) && !clientId) throw new Error(`${def.name} needs an OAuth client first. ${def.setupHelp}`);
		const loginId = randomUUID();
		const login: Login = { connector, abort: new AbortController() };
		this.logins.set(loginId, login);
		const emit = (event: ProviderAuthEvent) => this.options.emit?.(loginId, connector, event);
		void (isMcp(def) ? this.signInMcp(def, login.abort.signal, emit) : this.signIn(def, clientId!, login.abort.signal, emit))
			.then(
				() => emit({ type: "done" }),
				(error: unknown) => emit({ type: "failed", message: login.abort.signal.aborted ? "Cancelled." : error instanceof Error ? error.message : String(error) }),
			)
			.finally(() => {
				this.logins.delete(loginId);
				this.onChange?.();
			});
		this.onChange?.();
		return loginId;
	}

	cancel(loginId: string): void {
		this.logins.get(loginId)?.abort.abort();
	}

	/** MCP apps: the server's own sign-in, then its tools and who signed in. */
	private async signInMcp(def: McpConnector, signal: AbortSignal, emit: (e: ProviderAuthEvent) => void): Promise<void> {
		const state = await signInMcp(def, def.mcp.url, signal, emit, page);
		const io = memoryIO();
		io.state = state;
		const session = new McpAccount(def, def.mcp.url, io, this.options.fetchImpl);
		try {
			const tools = toolInfos(def, await session.tools());
			const who = (await def.mcp.identify?.(session.call, tools).catch(() => undefined)) ?? { id: "default", label: def.name };
			const account: Account = { id: `${def.id}:${who.id}`, connector: def.id, label: who.label, addedAt: new Date().toISOString() };
			await this.secrets.set(this.secretName(account.id), JSON.stringify(io.state ?? state));
			await this.mcp.get(account.id)?.close();
			this.mcp.delete(account.id);
			this.state.accounts = [...this.state.accounts.filter((a) => a.id !== account.id), account];
			this.state.tools = { ...this.state.tools, [def.id]: tools };
			this.problems.delete(account.id);
			this.save();
		} finally {
			await session.close();
		}
	}

	private async signIn(def: ApiConnector, clientId: string, signal: AbortSignal, emit: (e: ProviderAuthEvent) => void): Promise<void> {
		const verifier = randomBytes(32).toString("base64url");
		const challenge = createHash("sha256").update(verifier).digest("base64url");
		const state = randomBytes(16).toString("base64url");
		const { server, port, code } = await loopback(def.oauth.loopbackHost, state, signal);
		try {
			const redirectUri = `http://${def.oauth.loopbackHost}:${port}/callback`;
			const params = new URLSearchParams({
				client_id: clientId,
				response_type: "code",
				redirect_uri: redirectUri,
				scope: def.oauth.scopes.join(" "),
				state,
				code_challenge: challenge,
				code_challenge_method: "S256",
				...def.oauth.extraParams,
			});
			emit({ type: "auth_url", url: `${def.oauth.authorizeUrl}?${params}`, instructions: `Sign in to ${def.name} in your browser. This updates when you're done.` });
			const authCode = await withTimeout(code, LOGIN_TIMEOUT_MS, "Sign-in timed out. Try again.");
			emit({ type: "progress", message: "Finishing sign-in…" });
			const secret = def.oauth.needsSecret ? await this.clientSecret(def.id) : undefined;
			const tokens = await this.token(def, { grant_type: "authorization_code", code: authCode, redirect_uri: redirectUri, code_verifier: verifier, client_id: clientId, ...(secret ? { client_secret: secret } : {}) });
			let current = tokens;
			const fetchFor: AuthorizedFetch = (path, init) => this.request(def, () => current, init, path);
			const who = await def.identify(fetchFor);
			const account: Account = { id: `${def.id}:${who.id}`, connector: def.id, label: who.label, addedAt: new Date().toISOString() };
			await this.secrets.set(this.secretName(account.id), JSON.stringify(tokens));
			this.state.accounts = [...this.state.accounts.filter((a) => a.id !== account.id), account];
			this.problems.delete(account.id);
			current = tokens;
			this.save();
		} finally {
			server.close();
		}
	}

	async disconnect(accountId: string): Promise<void> {
		await this.mcp.get(accountId)?.close();
		this.mcp.delete(accountId);
		await this.secrets.delete(this.secretName(accountId));
		this.state.accounts = this.state.accounts.filter((a) => a.id !== accountId);
		if (this.state.calendars) delete this.state.calendars[accountId];
		this.problems.delete(accountId);
		this.save();
	}

	// ── Requests ──

	private secretName(accountId: string): string {
		const [connector, ...rest] = accountId.split(":");
		return `connector.${connector}.${rest.join(":")}`;
	}

	private async token(def: ApiConnector, form: Record<string, string>): Promise<Tokens> {
		const response = await this.fetchImpl(def.oauth.tokenUrl, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(form), signal: AbortSignal.timeout(20_000) });
		const body = (await response.json().catch(() => ({}))) as { access_token?: string; refresh_token?: string; expires_in?: number; error?: string; error_description?: string };
		if (!response.ok || !body.access_token) throw new Error(`${def.name} didn't complete the sign-in: ${body.error_description ?? body.error ?? response.status}`);
		return { access: body.access_token, ...(body.refresh_token ? { refresh: body.refresh_token } : {}), expires: Date.now() + (body.expires_in ?? 3600) * 1000 };
	}

	private async request(def: ApiConnector, tokens: () => Tokens, init: RequestInit | undefined, path: string): Promise<Response> {
		const url = /^https?:\/\//.test(path) ? path : `${def.apiBase}${path}`;
		const headers = new Headers(init?.headers);
		headers.set("authorization", `Bearer ${tokens().access}`);
		return this.fetchImpl(url, { ...init, headers, signal: init?.signal ?? AbortSignal.timeout(30_000) });
	}

	/** A fetch for one account that refreshes the token when it's about to expire or the API says it's stale. */
	authorized(account: Account): AuthorizedFetch {
		const def = this.definition(account.connector);
		if (!def || isMcp(def)) throw new Error(`${account.connector} isn't an app with its own API.`);
		let cached: Tokens | undefined;
		const load = async (): Promise<Tokens> => {
			if (cached) return cached;
			const raw = await this.secrets.get(this.secretName(account.id), `Use ${def.name}`);
			if (!raw) throw new NeedsSignIn(`${def.name} (${account.label}) isn't signed in on this Mac. Reconnect it in Settings › Connectors.`);
			cached = JSON.parse(raw) as Tokens;
			return cached;
		};
		const refresh = async (): Promise<Tokens> => {
			const current = await load();
			if (!current.refresh) throw new NeedsSignIn(`${def.name} (${account.label}) needs you to sign in again.`);
			const clientId = this.clientId(def.id);
			const secret = def.oauth.needsSecret ? await this.clientSecret(def.id) : undefined;
			try {
				const next = await this.token(def, { grant_type: "refresh_token", refresh_token: current.refresh, client_id: clientId ?? "", ...(secret ? { client_secret: secret } : {}) });
				cached = { ...next, refresh: next.refresh ?? current.refresh };
				await this.secrets.set(this.secretName(account.id), JSON.stringify(cached));
				return cached;
			} catch {
				throw new NeedsSignIn(`${def.name} (${account.label}) needs you to sign in again.`);
			}
		};
		return async (path, init) => {
			try {
				let tokens = await load();
				if (tokens.expires < Date.now() + 60_000) tokens = await refresh();
				let response = await this.request(def, () => tokens, init, path);
				if (response.status === 401) {
					tokens = await refresh();
					response = await this.request(def, () => tokens, init, path);
				}
				if (this.problems.delete(account.id)) this.onChange?.();
				return response;
			} catch (error) {
				if (error instanceof NeedsSignIn) {
					this.problems.set(account.id, error.message);
					this.onChange?.();
				}
				throw error;
			}
		};
	}

	/**
	 * Calendars to read: every connected account with one (in chats, only connectors allowed there, minus those the
	 * conversation turned off: `off`).
	 */
	calendars(scope: "chat" | "agent", off: (connector: string) => boolean = () => false): { account: Account; calendar: Calendar; name: string }[] {
		return this.state.accounts.flatMap((account) => {
			const def = this.definition(account.connector);
			if (!def || isMcp(def) || !def.calendar || (scope === "chat" && (!this.settings(def.id).chats || off(def.id)))) return [];
			const calendar = def.calendar(this.authorized(account));
			const chosen = this.state.calendars?.[account.id];
			// Calendars turned off in Settings aren't read.
			const read: Calendar = chosen ? { ...calendar, events: (range) => calendar.events({ ...range, include: (id, shown) => chosen[id] ?? shown }) } : calendar;
			return [{ account, calendar: read, name: def.name }];
		});
	}

	mailboxes(scope: "chat" | "agent", off: (connector: string) => boolean = () => false): { account: Account; mailbox: Mailbox; name: string }[] {
		return this.state.accounts.flatMap((account) => {
			const def = this.definition(account.connector);
			if (!def || isMcp(def) || !def.mailbox || (scope === "chat" && (!this.settings(def.id).chats || off(def.id)))) return [];
			return [{ account, mailbox: def.mailbox(this.authorized(account)), name: def.name }];
		});
	}

	// ── MCP apps (Linear) ──

	/** An account's connection to its app's server; its OAuth state lives in the Keychain. */
	private mcpAccount(account: Account, def: McpConnector): McpAccount {
		let session = this.mcp.get(account.id);
		if (!session) {
			const name = this.secretName(account.id);
			const io: StateIO = {
				load: async () => {
					const raw = await this.secrets.get(name, `Use ${def.name}`);
					return raw ? (JSON.parse(raw) as McpOAuthState) : undefined;
				},
				save: async (state) => {
					await this.secrets.set(name, JSON.stringify(state));
				},
			};
			session = new McpAccount(def, def.mcp.url, io, this.options.fetchImpl);
			this.mcp.set(account.id, session);
		}
		return session;
	}

	/** Calls through an account, noting when it needs a new sign-in (Settings shows it) and when it works again. */
	private mcpCall(account: Account, def: McpConnector): McpCall {
		return async (tool, args) => {
			try {
				const result = await this.mcpAccount(account, def).call(tool, args);
				if (this.problems.delete(account.id)) this.onChange?.();
				return result;
			} catch (error) {
				if (error instanceof McpNeedsSignIn) {
					const message = `${def.name} (${account.label}) needs you to sign in again. Reconnect it in Settings › Connectors.`;
					this.problems.set(account.id, message);
					this.onChange?.();
					throw new NeedsSignIn(message);
				}
				throw error;
			}
		};
	}

	/** MCP apps' accounts a conversation may use (in chats, only apps allowed there and not turned off here). */
	mcpUses(scope: "chat" | "agent", off: (connector: string) => boolean = () => false): McpUse[] {
		return this.state.accounts.flatMap((account) => {
			const def = this.definition(account.connector);
			if (!def || !isMcp(def) || (scope === "chat" && (!this.settings(def.id).chats || off(def.id)))) return [];
			return [{ account, def, tools: this.state.tools?.[def.id] ?? [], call: this.mcpCall(account, def) }];
		});
	}

	/** Asks each connected MCP app's server for its tools again (at start, in the background): new ones reach new conversations. */
	async refreshMcpTools(): Promise<void> {
		for (const def of this.definitions.filter(isMcp)) {
			const account = this.accounts(def.id)[0];
			if (!account) continue;
			try {
				const tools = toolInfos(def, await this.mcpAccount(account, def).tools());
				if (JSON.stringify(tools) !== JSON.stringify(this.state.tools?.[def.id])) {
					this.state.tools = { ...this.state.tools, [def.id]: tools };
					this.save();
				}
			} catch (error) {
				if (error instanceof McpNeedsSignIn) {
					this.problems.set(account.id, `${def.name} (${account.label}) needs you to sign in again. Reconnect it in Settings › Connectors.`);
					this.onChange?.();
				}
			}
		}
	}

	async close(): Promise<void> {
		await Promise.all([...this.mcp.values()].map((m) => m.close()));
		this.mcp.clear();
	}
}

export class NeedsSignIn extends Error {}

/** The browser page after a sign-in. */
function page(title: string, text: string): string {
	return `<!doctype html><meta charset="utf-8"><title>${title}</title><body style="font:15px -apple-system;margin:80px auto;max-width:420px;text-align:center"><h2>${title}</h2><p>${text}</p></body>`;
}

/** A one-shot loopback server for the OAuth redirect; resolves with the code once the browser comes back. */
async function loopback(host: string, state: string, signal: AbortSignal): Promise<{ server: Server; port: number; code: Promise<string> }> {
	let resolve!: (code: string) => void;
	let reject!: (error: Error) => void;
	const code = new Promise<string>((res, rej) => {
		resolve = res;
		reject = rej;
	});
	const server = createServer((req, res) => {
		const url = new URL(req.url ?? "/", "http://localhost");
		if (url.pathname !== "/callback") return void res.writeHead(404).end();
		const page = (title: string, text: string) => `<!doctype html><meta charset="utf-8"><title>${title}</title><body style="font:15px -apple-system;margin:80px auto;max-width:420px;text-align:center"><h2>${title}</h2><p>${text}</p></body>`;
		if (url.searchParams.get("state") !== state) {
			res.writeHead(400, { "content-type": "text/html" }).end(page("Something went wrong", "This sign-in link is out of date. Start again from Piopio."));
			return;
		}
		const error = url.searchParams.get("error");
		const got = url.searchParams.get("code");
		if (error || !got) {
			res.writeHead(400, { "content-type": "text/html" }).end(page("Not connected", "The sign-in was cancelled or refused. You can close this tab."));
			reject(new Error(error === "access_denied" ? "The sign-in was cancelled." : `The sign-in failed: ${error ?? "no code"}.`));
			return;
		}
		res.writeHead(200, { "content-type": "text/html" }).end(page("Connected", "You can close this tab and go back to Piopio."));
		resolve(got);
	});
	signal.addEventListener("abort", () => reject(new Error("Cancelled.")), { once: true });
	await new Promise<void>((res, rej) => {
		server.once("error", rej);
		server.listen(0, host === "localhost" ? "127.0.0.1" : host, () => res());
	});
	return { server, port: (server.address() as { port: number }).port, code };
}

function withTimeout<T>(promise: Promise<T>, ms: number, message: string): Promise<T> {
	return new Promise<T>((resolve, reject) => {
		const t = setTimeout(() => reject(new Error(message)), ms);
		promise.then((v) => (clearTimeout(t), resolve(v)), (e) => (clearTimeout(t), reject(e)));
	});
}
