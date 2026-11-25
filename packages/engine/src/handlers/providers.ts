/**
 * The engine's `providers.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `providers.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import { connectMethods } from "../providers.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function providersHandlers(engine: Engine): Handlers<"providers"> {
	return {
		"providers.list": async (_params, _call) => {
			return { providers: await engine.hub.listProviders((id) => engine.logins.connecting(id)) } satisfies Result<"providers.list">;
		},
		"providers.login": async (params, _call) => {
			const p = params as Params<"providers.login">;
			const provider = engine.hub.models.getProvider(p.provider);
			if (!provider) throw new EngineError("NOT_FOUND", `Unknown provider ${p.provider}`);
			if (!connectMethods(provider).some((m) => m.type === p.method)) throw new EngineError("INVALID", `${provider.name} can't be connected that way.`);
			const loginId = engine.logins.start(p.provider, p.method);
			for (const c of engine.authed) c.notify("providers.changed", {});
			return { loginId } satisfies Result<"providers.login">;
		},
		"providers.answer": async (params, _call) => {
			const p = params as Params<"providers.answer">;
			engine.logins.answer(p.loginId, p.promptId, p.value);
			return {};
		},
		"providers.cancelLogin": async (params, _call) => {
			const p = params as Params<"providers.cancelLogin">;
			engine.logins.cancel(p.loginId);
			return {};
		},
		"providers.verifyKey": async (params, _call) => {
			const p = params as Params<"providers.verifyKey">;
			return (await engine.hub.verifyProviderKey(p.provider, p.key)) satisfies Result<"providers.verifyKey">;
		},
		"providers.saveKey": async (params, _call) => {
			const p = params as Params<"providers.saveKey">;
			await engine.hub.saveKey(p.provider, p.key);
			for (const c of engine.authed) c.notify("providers.changed", {});
			return {};
		},
		"providers.models": async (params, _call) => {
			const p = params as Params<"providers.models">;
			return { models: await engine.hub.providerModels(p.provider) } satisfies Result<"providers.models">;
		},
		"providers.setHidden": async (params, _call) => {
			const p = params as Params<"providers.setHidden">;
			engine.hub.setHidden(p.provider, p.hidden);
			for (const c of engine.authed) c.notify("providers.changed", {});
			return {};
		},
		"providers.logout": async (params, _call) => {
			const p = params as Params<"providers.logout">;
			await engine.hub.logout(p.provider);
			for (const c of engine.authed) c.notify("providers.changed", {});
			return {};
		},
	};
}
