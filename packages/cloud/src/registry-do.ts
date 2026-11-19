/**
 * RegistryDO (docs/spec/30 §8, K1): one object, named "registry", that knows which agents live in this Worker. An
 * AgentDO adds itself when the Mac deploys it and removes itself when it's retired; `GET /v1/agents` reads the list.
 * Durable Objects can't be enumerated, so without it a reinstalled Mac (or the phone, K3) couldn't find its agents.
 * Later phases keep routing, deploy history and the Mac Bridge's connection here too.
 */
import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env.js";

export type RegisteredAgent = { id: string; name: string; avatar?: string; deployedAt: string };

const PREFIX = "agent:";

export class RegistryDO extends DurableObject<Env> {
	async put(agent: RegisteredAgent): Promise<void> {
		await this.ctx.storage.put(`${PREFIX}${agent.id}`, agent);
	}

	async remove(id: string): Promise<void> {
		await this.ctx.storage.delete(`${PREFIX}${id}`);
	}

	async list(): Promise<RegisteredAgent[]> {
		const all = await this.ctx.storage.list<RegisteredAgent>({ prefix: PREFIX });
		return [...all.values()].sort((a, b) => a.name.localeCompare(b.name));
	}
}

export const REGISTRY_NAME = "registry";
