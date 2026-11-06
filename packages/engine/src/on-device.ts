/**
 * Apple's on-device model (Foundation Models) for utility work (docs/spec/07-shared §1.3), through `piopio-fm`, a
 * small helper in Piopio.app (apps/mac/App/OnDeviceModel). The engine runs it as a child process, so it works with
 * the window closed and in background mode. `PIOPIO_FM` is its path: the app and the engine launcher set it.
 */
import { execFile } from "node:child_process";

/** Apple's model can't run now (Apple Intelligence off, not downloaded, no helper): the task is skipped. */
export class OnDeviceUnavailable extends Error {}

export type OnDeviceStatus = { available: boolean; reason?: string };

/** The on-device model's context is about 4,000 tokens for instructions, input and answer together. */
export const ON_DEVICE_MAX_INPUT = 9_000;
const STATUS_TTL_MS = 60_000;

export class OnDeviceModel {
	private cached?: { at: number; status: OnDeviceStatus };

	constructor(private readonly helper: string | undefined = process.env.PIOPIO_FM || undefined) {}

	async status(): Promise<OnDeviceStatus> {
		if (!this.helper) return { available: false, reason: "Apple's on-device model runs through the Piopio app, which isn't installed with this engine." };
		if (this.cached && Date.now() - this.cached.at < STATUS_TTL_MS) return this.cached.status;
		let status: OnDeviceStatus;
		try {
			const out = await this.run(["--status"]);
			status = out.available === true ? { available: true } : { available: false, reason: typeof out.reason === "string" ? out.reason : "Apple's on-device model isn't available." };
		} catch (error) {
			status = { available: false, reason: (error as Error).message };
		}
		this.cached = { at: Date.now(), status };
		return status;
	}

	/** One answer. Throws `OnDeviceUnavailable` when the model can't run now. */
	async complete(instructions: string, prompt: string): Promise<string> {
		const status = await this.status();
		if (!status.available) throw new OnDeviceUnavailable(status.reason ?? "Apple's on-device model isn't available.");
		const clipped = prompt.length > ON_DEVICE_MAX_INPUT ? `${prompt.slice(0, ON_DEVICE_MAX_INPUT)}\n[…]` : prompt;
		const out = await this.run([], JSON.stringify({ instructions, prompt: clipped }));
		if (typeof out.text === "string") return out.text.trim();
		if (out.unavailable) this.cached = { at: Date.now(), status: { available: false, reason: String(out.error) } };
		const message = typeof out.error === "string" ? out.error : "Apple's on-device model failed.";
		throw out.unavailable ? new OnDeviceUnavailable(message) : new Error(message);
	}

	private run(args: string[], input?: string): Promise<Record<string, unknown>> {
		return new Promise((resolve, reject) => {
			const child = execFile(this.helper!, args, { timeout: 90_000, maxBuffer: 1024 * 1024 }, (error, stdout) => {
				try {
					// The helper answers in JSON on stdout, also when it exits with an error.
					resolve(JSON.parse(stdout.trim().split("\n").at(-1) || "{}") as Record<string, unknown>);
				} catch {
					reject(new Error(error ? `Apple's on-device model couldn't start: ${error.message}` : "Apple's on-device model answered something unexpected."));
				}
			});
			child.stdin?.end(input ?? "");
		});
	}
}
