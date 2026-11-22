/**
 * RegistryDO (docs/spec/30 §8, K1): one object, named "registry", that knows which agents live in this Worker. An
 * AgentDO adds itself when the Mac deploys it and removes itself when it's retired; `GET /v1/agents` reads the list.
 * Durable Objects can't be enumerated, so without it a reinstalled Mac (or the phone, K3) couldn't find its agents.
 * Later phases keep routing, deploy history and the Mac Bridge's connection here too.
 */
import { DurableObject } from "cloudflare:workers";
import { sameSecret } from "./auth.js";
import type { Env } from "./env.js";

export type RegisteredAgent = { id: string; name: string; avatar?: string; deployedAt: string };

const PREFIX = "agent:";
const WEBHOOK = "webhook:";

export class RegistryDO extends DurableObject<Env> {
	async put(agent: RegisteredAgent): Promise<void> {
		await this.ctx.storage.put(`${PREFIX}${agent.id}`, agent);
	}

	async remove(id: string): Promise<void> {
		await this.ctx.storage.delete(`${PREFIX}${id}`);
	}

	/**
	 * An agent's Telegram webhook secret (or none: no webhook), kept here so the Worker turns away a POST without it
	 * before any agent's object starts: starting one opens pi and its tasks, and any name makes a new object.
	 */
	async setWebhook(id: string, secret: string | undefined): Promise<void> {
		if (secret) await this.ctx.storage.put(`${WEBHOOK}${id}`, secret);
		else await this.ctx.storage.delete(`${WEBHOOK}${id}`);
	}

	async webhookAllowed(id: string, given: string): Promise<boolean> {
		const secret = await this.ctx.storage.get<string>(`${WEBHOOK}${id}`);
		return secret !== undefined && (await sameSecret(given, secret));
	}

	async list(): Promise<RegisteredAgent[]> {
		const all = await this.ctx.storage.list<RegisteredAgent>({ prefix: PREFIX });
		return [...all.values()].sort((a, b) => a.name.localeCompare(b.name));
	}
}

export const REGISTRY_NAME = "registry";
