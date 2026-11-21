import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { AgentFileStore } from "../src/agent-file-store.js";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// Files kept per agent (docs/spec/06-agents §14): what the owner sends is kept in the agent's folder, and it reads,
// notes, hands over and deletes them later.

const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

test("the store keeps originals and what the model read, notes, renames, deletes with Undo, and stays out of git", async () => {
	const folder = mkdtempSync(join(tmpdir(), "piopio-agent-folder-"));
	const pdf = join(folder, "..", `poliza-${Date.now()}.pdf`);
	writeFileSync(pdf, "%PDF-1.4 not really");
	const store = new AgentFileStore(folder);
	const kept = store.keep(
		[
			{ kind: "text", name: "poliza.pdf", mimeType: "application/pdf", text: "Mapfre. Vence el 14 de enero de 2027.", path: pdf },
			{ kind: "image", name: "ruedas.png", mimeType: "image/png", data: PNG },
		],
		{ from: "owner" },
	);
	expect(kept.map((f) => [f.name, f.kind, f.readable])).toEqual([
		["poliza.pdf", "pdf", true],
		["ruedas.png", "image", true],
	]);
	expect(readFileSync(join(folder, "files", "poliza.pdf"), "utf8")).toBe("%PDF-1.4 not really");
	expect(readFileSync(join(folder, ".gitignore"), "utf8")).toBe("files/\n");
	expect(await store.read("poliza.pdf")).toEqual({ text: "Mapfre. Vence el 14 de enero de 2027.", total: 37 });
	expect(await store.read("ruedas.png")).toEqual({ image: { data: PNG, mimeType: "image/png" } });

	// The same name again is a second file.
	expect(store.keep([{ kind: "text", name: "poliza.pdf", mimeType: "application/pdf", text: "Otra" }])[0]!.name).toBe("poliza 2.pdf");

	const renamed = await store.note("poliza.pdf", { note: "Póliza Mapfre 2026–27", rename: "seguro-2026" });
	expect(renamed).toMatchObject({ name: "seguro-2026.pdf", note: "Póliza Mapfre 2026–27" });
	expect(await store.read("seguro-2026.pdf")).toMatchObject({ text: expect.stringContaining("14 de enero") });

	const { token } = await store.remove("seguro-2026.pdf");
	expect((await store.list()).map((f) => f.name)).not.toContain("seguro-2026.pdf");
	await store.restore(token);
	expect((await store.list()).find((f) => f.name === "seguro-2026.pdf")).toMatchObject({ note: "Póliza Mapfre 2026–27", readable: true });

	// A PDF dropped in Finder: listed, but no text to read until it's sent.
	writeFileSync(join(folder, "files", "itv.pdf"), "%PDF");
	expect((await store.list()).find((f) => f.name === "itv.pdf")).toMatchObject({ kind: "pdf", readable: false });
	expect(await store.read("itv.pdf")).toEqual({ error: expect.stringContaining("No text is kept for itv.pdf") });
	expect(await store.read("nope.txt")).toEqual({ error: expect.stringContaining("No file named nope.txt") });
});

const open: { engine: Engine; client: TestClient }[] = [];
afterEach(async () => {
	for (const o of open.splice(0)) {
		o.client.close();
		await o.engine.stop();
	}
});

async function start(home = mkdtempSync(join(tmpdir(), "piopio-files-"))) {
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), teamsDir: join(home, "Teams"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	open.push({ engine, client });
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: [] });
	return { home, client };
}

async function until<T>(get: () => Promise<T> | T, ok: (v: T) => boolean, ms = 20_000): Promise<T> {
	const end = Date.now() + ms;
	for (;;) {
		const v = await get();
		if (ok(v)) return v;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(v).slice(0, 1200)}`);
		await new Promise((r) => setTimeout(r, 80));
	}
}

const call = (tool: string, args: object) => `call: ${tool} | ${JSON.stringify(args)}`;

test("a file sent to an agent is kept; it reads it, hands it over as a card, and deletes it with Undo", async () => {
	const { client } = await start();
	const { ref } = await client.call("agents.create", { name: "Coche", owner: "Antonio", model: { provider: "faux", id: "faux-1" } });
	const got = await client.call("agents.get", { ref });
	expect((got.definition as { tools: { builtin: string[] } }).tools.builtin).toContain("files");
	await client.call("agents.save", { ref, definition: { ...(got.definition as object), interview: undefined }, instructions: got.instructions });
	await client.call("sessions.subscribe", { ref });
	const items = () => client.call("sessions.open", { ref }).then((s) => JSON.stringify(s.items));

	// Sent in the chat (the app sends a PDF's text and where the original is): kept on its own, and read back.
	const original = join(mkdtempSync(join(tmpdir(), "piopio-sent-")), "poliza.pdf");
	writeFileSync(original, "%PDF-1.4");
	await client.call("sessions.submit", {
		ref,
		input: { text: call("read_file", { name: "poliza.pdf" }), attachments: [{ kind: "text", name: "poliza.pdf", mimeType: "application/pdf", text: "Mapfre. Vence el 14 de enero de 2027.", path: original }] },
	});
	await until(items, (s) => s.includes("Vence el 14 de enero de 2027"));
	const listed = (await client.call("agents.files", { ref })) as { files: { name: string; path: string }[]; folder: string };
	expect(listed.files.map((f) => f.name)).toEqual(["poliza.pdf"]);
	expect(listed.folder).toMatch(/Agents\/coche\/files$/);
	expect(readFileSync(join(listed.folder, "poliza.pdf"), "utf8")).toBe("%PDF-1.4");

	// Handed over: a card of its own, with where the file is.
	await client.call("sessions.submit", { ref, input: { text: call("present_files", { names: ["poliza.pdf"] }) } });
	const shown = await until(
		() => client.call("sessions.open", { ref }),
		(s) => (s.items as { kind: string; tool?: string; status?: string }[]).some((i) => i.kind === "tool" && i.tool === "present_files" && i.status === "done"),
	);
	const card = (shown.items as { kind: string; tool?: string; details?: { type: string; files: { path: string }[] } }[]).find((i) => i.tool === "present_files")!;
	expect(card.details).toMatchObject({ type: "files", files: [{ path: listed.files[0]!.path }] });

	// Deleted, then Undo puts it back.
	await client.call("sessions.submit", { ref, input: { text: call("delete_file", { name: "poliza.pdf" }) } });
	const after = await until(
		() => client.call("sessions.open", { ref }),
		(s) => (s.items as { kind: string; card?: { kind: string } }[]).some((i) => i.kind === "result" && i.card?.kind === "file"),
	);
	expect(((await client.call("agents.files", { ref })) as { files: unknown[] }).files).toHaveLength(0);
	const result = (after.items as { kind: string; card?: { kind: string }; undo?: { id: string } }[]).find((i) => i.kind === "result" && i.card?.kind === "file")!;
	await client.call("agents.undo", { ref, undoId: result.undo!.id });
	expect(((await client.call("agents.files", { ref })) as { files: { name: string }[] }).files.map((f) => f.name)).toEqual(["poliza.pdf"]);

	// From the app: added, noted, deleted.
	const added = (await client.call("agents.files.add", { ref, attachments: [{ kind: "image", name: "ruedas.png", mimeType: "image/png", data: PNG }] })) as { files: { name: string }[] };
	expect(added.files.map((f) => f.name)).toEqual(["ruedas.png"]);
	expect(await client.call("agents.files.note", { ref, name: "ruedas.png", note: "Neumáticos, mayo 2026" })).toMatchObject({ note: "Neumáticos, mayo 2026" });
	await client.call("agents.files.delete", { ref, name: "ruedas.png" });
	expect(existsSync(join(listed.folder, "ruedas.png"))).toBe(false);
}, 60_000);

test("an agent with no files has none, and nothing is made in its folder", async () => {
	const folder = mkdtempSync(join(tmpdir(), "piopio-agent-folder-"));
	const store = new AgentFileStore(folder);
	expect(await store.list()).toEqual([]);
	expect(existsSync(join(folder, "files"))).toBe(false);
});
