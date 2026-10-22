/**
 * Secrets live in the app's Keychain. The engine asks the connected client with a reverse
 * `secrets.get` request and caches the answer in memory only; provider sign-ins and refreshed
 * tokens go back with `secrets.set` / `secrets.delete` (clients that offer them).
 * Dev fallback: `PIOPIO_ALLOW_ENV_SECRETS=1` lets `OPENROUTER_API_KEY` from the environment answer.
 */
import { SECRET_OPENROUTER } from "@piopio/protocol";

export type SecretRequester = (name: string, purpose: string) => Promise<string | null>;
/** A client that can also store and remove secrets. */
export type SecretWriter = { set(name: string, value: string): Promise<void>; delete(name: string): Promise<void> };

const ENV_FALLBACK: Record<string, string> = { [SECRET_OPENROUTER]: "OPENROUTER_API_KEY" };

export class SecretBroker {
	private requesters: SecretRequester[] = [];
	private writers: SecretWriter[] = [];
	private cache = new Map<string, string>();
	/** Writes made while no client could store them; flushed when one connects. */
	private pending = new Map<string, string | null>();

	constructor(private readonly env: NodeJS.ProcessEnv = process.env) {}

	/** Registers a client able to answer `secrets.get` (and store secrets, given a writer); returns an unregister function. */
	addRequester(requester: SecretRequester, writer?: SecretWriter): () => void {
		this.requesters.push(requester);
		if (writer) {
			this.writers.push(writer);
			void this.flush();
		}
		return () => {
			this.requesters = this.requesters.filter((r) => r !== requester);
			if (writer) this.writers = this.writers.filter((w) => w !== writer);
		};
	}

	/** Whether any client can answer right now (a miss without one isn't an answer). */
	get connected(): boolean {
		return this.requesters.length > 0;
	}

	/** Stores a secret in the client's Keychain; kept in memory (and retried) when no client can store it. */
	async set(name: string, value: string): Promise<void> {
		this.cache.set(name, value);
		this.pending.set(name, value);
		await this.flush();
	}

	async delete(name: string): Promise<void> {
		this.cache.delete(name);
		this.pending.set(name, null);
		await this.flush();
	}

	private async flush(): Promise<void> {
		const writer = this.writers.at(-1);
		if (!writer) return;
		for (const [name, value] of [...this.pending]) {
			try {
				if (value === null) await writer.delete(name);
				else await writer.set(name, value);
				if (this.pending.get(name) === value) this.pending.delete(name);
			} catch {
				// keep it for the next client
			}
		}
	}

	async get(name: string, purpose: string): Promise<string | null> {
		const cached = this.cache.get(name);
		if (cached) return cached;
		if (this.pending.get(name) === null) return null;
		// Newest client first: it is the one the user is looking at.
		for (const requester of [...this.requesters].reverse()) {
			try {
				const value = await requester(name, purpose);
				if (value) {
					this.cache.set(name, value);
					return value;
				}
			} catch {
				// try the next client
			}
		}
		const envName = ENV_FALLBACK[name];
		if (this.env.PIOPIO_ALLOW_ENV_SECRETS === "1" && envName && this.env[envName]) {
			const value = this.env[envName]!;
			this.cache.set(name, value);
			return value;
		}
		return null;
	}

	forget(name: string): void {
		this.cache.delete(name);
	}
}
