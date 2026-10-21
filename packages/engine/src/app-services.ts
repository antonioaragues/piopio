/**
 * App services (docs/spec/03-engine-protocol §3.12): things only the Mac app can do, asked for with reverse
 * requests. Clients say in `engine.hello` which they answer. The newest client is asked first; with none (background
 * mode, app closed) the call fails with `AppUnavailable` and the tool says so.
 */
import type { ReverseParams, ReverseResult } from "@piopio/protocol";
import { AppUnavailable } from "@piopio/runtime";

export type AppToolRequester = (params: ReverseParams<"app.tool">) => Promise<ReverseResult<"app.tool">>;

export class AppServices {
	private tools: AppToolRequester[] = [];

	/** A client that answers `app.tool`; returns an unregister function. */
	addToolServer(requester: AppToolRequester): () => void {
		this.tools.push(requester);
		return () => {
			this.tools = this.tools.filter((r) => r !== requester);
		};
	}

	get connected(): boolean {
		return this.tools.length > 0;
	}

	async tool(params: ReverseParams<"app.tool">): Promise<ReverseResult<"app.tool">> {
		let last: unknown;
		for (const requester of [...this.tools].reverse()) {
			try {
				return await requester(params);
			} catch (error) {
				last = error;
			}
		}
		if (last) throw last instanceof Error ? last : new Error(String(last));
		throw new AppUnavailable("No Mac app is connected.");
	}
}
