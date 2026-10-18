/**
 * Secrets live in the app's Keychain. The engine asks the connected client with a reverse
 * `secrets.get` request and caches the answer in memory only.
 * Dev fallback: `PIOPIO_ALLOW_ENV_SECRETS=1` lets `OPENROUTER_API_KEY` from the environment answer.
 */
import { SECRET_OPENROUTER } from "@piopio/protocol";

export type SecretRequester = (name: string, purpose: string) => Promise<string | null>;

const ENV_FALLBACK: Record<string, string> = { [SECRET_OPENROUTER]: "OPENROUTER_API_KEY" };

export class SecretBroker {
	private requesters: SecretRequester[] = [];
	private cache = new Map<string, string>();

	constructor(private readonly env: NodeJS.ProcessEnv = process.env) {}

	/** Registers a client able to answer `secrets.get`; returns an unregister function. */
	addRequester(requester: SecretRequester): () => void {
		this.requesters.push(requester);
		return () => {
			this.requesters = this.requesters.filter((r) => r !== requester);
		};
	}

	async get(name: string, purpose: string): Promise<string | null> {
		const cached = this.cache.get(name);
		if (cached) return cached;
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
