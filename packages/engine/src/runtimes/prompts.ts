/**
 * Things a Build session waits on the user for (approvals, ask_user questions, extensions' confirm/select/input).
 * Pending prompts are part of the session state, so a client that reconnects sees them again.
 */
import { randomUUID } from "node:crypto";
import type { ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import type { PendingPrompt, PromptResponse } from "@piopio/protocol";
import { EngineError } from "../models.js";

export type PromptRequest = Omit<PendingPrompt, "id" | "at">;

export class PromptBroker {
	private pending = new Map<string, { prompt: PendingPrompt; resolve: (response: PromptResponse | undefined) => void }>();
	/** Called on every add/remove with the full list and the prompt that changed. */
	onChange?: (prompts: PendingPrompt[], changed: PendingPrompt, added: boolean) => void;
	/** A new prompt (for notifications). */
	onAdded?: (prompt: PendingPrompt) => void;

	list(): PendingPrompt[] {
		return [...this.pending.values()].map((p) => p.prompt);
	}

	/** Waits for the user. Resolves undefined when `signal` aborts (the run was stopped). */
	ask(request: PromptRequest, signal?: AbortSignal): Promise<PromptResponse | undefined> {
		if (signal?.aborted) return Promise.resolve(undefined);
		const prompt: PendingPrompt = { ...request, id: `prm_${randomUUID().replaceAll("-", "").slice(0, 16)}`, at: new Date().toISOString() };
		return new Promise((resolve) => {
			const onAbort = () => finish(undefined);
			const finish = (response: PromptResponse | undefined) => {
				if (!this.pending.delete(prompt.id)) return;
				signal?.removeEventListener("abort", onAbort);
				resolve(response);
				this.onChange?.(this.list(), prompt, false);
			};
			signal?.addEventListener("abort", onAbort, { once: true });
			this.pending.set(prompt.id, { prompt, resolve: finish });
			this.onChange?.(this.list(), prompt, true);
			this.onAdded?.(prompt);
		});
	}

	respond(promptId: string, response: PromptResponse): void {
		const entry = this.pending.get(promptId);
		if (!entry) throw new EngineError("NOT_FOUND", "That request was already answered or cancelled.");
		entry.resolve(response);
	}

	/** Stop: everything pending resolves as unanswered (approvals become denials). */
	cancelAll(): void {
		for (const { resolve } of [...this.pending.values()]) resolve(undefined);
	}
}

/**
 * `ctx.ui` for extensions running in Piopio: dialogs become prompt cards, notifications become notes,
 * and terminal-only UI (widgets, footers, custom components) does nothing.
 */
export function uiBridge(broker: PromptBroker, note: (level: "info" | "warn" | "error", text: string) => void): ExtensionUIContext {
	let warnedCustom = false;
	const plainTheme = new Proxy({}, { get: () => (...args: unknown[]) => String(args.at(-1) ?? "") });
	const ui: Partial<Record<keyof ExtensionUIContext, unknown>> = {
		select: async (title: string, options: string[], opts?: { signal?: AbortSignal }) => (await broker.ask({ kind: "select", title, options }, opts?.signal))?.choice,
		confirm: async (title: string, message: string, opts?: { signal?: AbortSignal }) => (await broker.ask({ kind: "confirm", title, message }, opts?.signal))?.confirmed ?? false,
		input: async (title: string, placeholder?: string, opts?: { signal?: AbortSignal }) =>
			(await broker.ask({ kind: "input", title, ...(placeholder ? { placeholder } : {}) }, opts?.signal))?.text,
		notify: (message: string, type?: "info" | "warning" | "error") => note(type === "error" ? "error" : type === "warning" ? "warn" : "info", message),
		custom: async () => {
			if (!warnedCustom) note("warn", "An extension has a terminal UI that Piopio can't display.");
			warnedCustom = true;
			return undefined;
		},
		theme: plainTheme,
		getEditorText: () => "",
		getAllThemes: () => [],
		setTheme: () => ({ success: false, error: "Piopio has no terminal themes" }),
	};
	return new Proxy(ui, {
		get: (target, key) => (key in target ? target[key as keyof ExtensionUIContext] : () => undefined),
	}) as unknown as ExtensionUIContext;
}
