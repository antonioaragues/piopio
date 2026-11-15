import { mkdirSync, mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { Projects } from "../src/projects.js";
import { linkedFoldersExtension } from "../src/runtimes/build.js";

function setup() {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "piopio-linked-")));
	const projects = new Projects(join(root, "projects.json"), join(root, "agent"), join(root, "Piopio"));
	const project = projects.create("Tesis");
	const biblio = join(root, "Documents", "Bibliografia");
	mkdirSync(biblio, { recursive: true });
	return { root, projects, project, biblio };
}

test("a project links folders, read only or editable, and keeps them across a restart (docs/spec/18 §18)", () => {
	const { root, projects, project, biblio } = setup();
	let info = projects.configure(project.id, { linkFolder: { path: biblio, edit: false } });
	expect(info.folders).toEqual([{ path: biblio, edit: false }]);
	// Linking again changes the access; it isn't listed twice.
	info = projects.configure(project.id, { linkFolder: { path: biblio, edit: true } });
	expect(info.folders).toEqual([{ path: biblio, edit: true }]);
	expect(projects.foldersFor(join(project.path, "capitulos"))).toEqual([{ path: biblio, edit: true }]);
	const again = new Projects(join(root, "projects.json"), join(root, "agent"), join(root, "Piopio"));
	expect(again.list().find((p) => p.id === project.id)?.folders).toEqual([{ path: biblio, edit: true }]);
	info = projects.configure(project.id, { unlinkFolder: biblio });
	expect(info.folders).toBeUndefined();
	expect(projects.foldersFor(project.path)).toEqual([]);
});

test("the project's own folder, one inside it, one that holds it or a missing one can't be linked", () => {
	const { root, projects, project } = setup();
	mkdirSync(join(project.path, "datos"));
	expect(() => projects.configure(project.id, { linkFolder: { path: project.path, edit: false } })).toThrow(/already part/);
	expect(() => projects.configure(project.id, { linkFolder: { path: join(project.path, "datos"), edit: false } })).toThrow(/already part/);
	expect(() => projects.configure(project.id, { linkFolder: { path: root, edit: false } })).toThrow(/contains the project/);
	expect(() => projects.configure(project.id, { linkFolder: { path: join(root, "nope"), edit: false } })).toThrow(/Not a folder/);
	expect(() => projects.configure(project.id, { linkFolder: { path: "relative", edit: false } })).toThrow(/absolute/);
});

test("every turn tells the model about the linked folders and what it may do there", () => {
	let handler: ((event: { systemPrompt: string }) => { systemPrompt: string } | undefined) | undefined;
	let folders = [] as { path: string; edit: boolean }[];
	linkedFoldersExtension(() => folders)({ on: (name: string, fn: typeof handler) => void (name === "before_agent_start" && (handler = fn)) } as never);
	expect(handler!({ systemPrompt: "Base" })).toBeUndefined();
	folders = [{ path: "/Users/me/Documents/Bibliografia", edit: false }, { path: "/Users/me/Lab/Datos", edit: true }];
	const prompt = handler!({ systemPrompt: "Base" })!.systemPrompt;
	expect(prompt.startsWith("Base\n\n")).toBe(true);
	expect(prompt).toContain("- /Users/me/Documents/Bibliografia (read only: read and search it, but don't change anything there)");
	expect(prompt).toContain("- /Users/me/Lab/Datos (part of the project: you may change files here");
});
