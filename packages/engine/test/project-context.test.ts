import { mkdtempSync, writeFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { BuiltinMemory } from "@piopio/runtime";
import type { ProjectInfo } from "@piopio/protocol";
import { projectBank, projectExtension, type ProjectContext } from "../src/project-context.js";

function memory() {
	const db = new DatabaseSync(":memory:");
	let n = 0;
	return new BuiltinMemory({ exec: (s) => db.exec(s), run: (s, ...p) => void db.prepare(s).run(...(p as never[])), all: (s, ...p) => db.prepare(s).all(...(p as never[])) as never }, () => `r${++n}`);
}

test("a conversation in a project is told its instructions, files and what the project remembers", async () => {
	const path = mkdtempSync(join(tmpdir(), "piopio-project-"));
	writeFileSync(join(path, "budget.md"), "Kitchen: 12k");
	const project = { id: "prj_k", name: "Kitchen renovation", path, folder: false, instructions: "Answer in metric." } as ProjectInfo;
	const mem = memory();
	let current: ProjectContext | undefined = { project, memory: mem };
	const ext = projectExtension(() => current) as unknown as { tools: { name: string; execute: (a: never) => Promise<{ output: { text: string }[]; isError?: boolean }> }[]; sections: { render: (c?: unknown) => Promise<string | undefined> }[] };
	const tool = (name: string) => ext.tools.find((t) => t.name === name)!;
	const render = () => ext.sections[0]!.render({});

	expect(await render()).toContain("“Kitchen renovation”");
	expect(await render()).toContain("Answer in metric.");
	expect(await render()).toContain("- budget.md (1 KB)");
	expect((await tool("read_project_file").execute({ name: "budget.md" } as never)).output[0]!.text).toBe("Kitchen: 12k");
	expect((await tool("remember_in_project").execute({ fact: "The sink moves 40 cm left." } as never)).output[0]!.text).toContain("Saved to Kitchen renovation");
	expect(await render()).toContain("What the project remembers:\n- The sink moves 40 cm left.");
	expect((await mem.list(projectBank("prj_k"), { kinds: ["fact"] })).records.map((r) => r.text)).toEqual(["The sink moves 40 cm left."]);

	current = undefined; // moved out of the project
	expect(await render()).toBeUndefined();
	expect((await tool("read_project_file").execute({ name: "budget.md" } as never)).isError).toBe(true);
});
