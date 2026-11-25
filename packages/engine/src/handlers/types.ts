/** The shape of a method's handler (handlers/index.ts). */
import type { MethodName, Params, Result } from "@piopio/protocol";
import type { RpcConnection } from "../rpc/connection.js";

/** The connection a call came on, and the subscriptions it owns (closed with it). */
export type Call = { conn: RpcConnection; owned: Set<string> };

export type Handler<M extends MethodName> = (params: Params<M>, call: Call) => Promise<Result<M>>;

/**
 * Methods only your cloud engine answers (docs/spec/30 K1, packages/cloud): the Mac's engine calls them there, it
 * doesn't serve them. A method the local engine should answer never goes here.
 */
export type CloudOnly = "agents.deploy" | "agents.export" | "agents.status" | "agents.retire";

/** The methods this engine answers: all but the cloud's. */
export type LocalMethod = Exclude<MethodName, CloudOnly>;

/** The handlers of the methods whose name starts with `prefix.`, every one of them. */
export type Handlers<Prefix extends string> = { [M in Extract<LocalMethod, `${Prefix}.${string}`>]: Handler<M> };

/** Every method's handler but `engine.hello`, which server.ts answers itself (it signs the connection in). */
export type AllHandlers = { [M in Exclude<LocalMethod, "engine.hello">]: Handler<M> };
