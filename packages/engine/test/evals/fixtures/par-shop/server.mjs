// The shop's dev server: the page in public/ and its products at /api/products.
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize } from "node:path";

const port = Number(process.env.PORT) || 5173;
const root = join(import.meta.dirname, "public");
const types = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8" };

const products = [
	{ id: 1, name: "Blue mug", price: 12 },
	{ id: 2, name: "Steel kettle", price: 34 },
	{ id: 3, name: "Oak tray", price: 27 },
];

createServer(async (req, res) => {
	const path = new URL(req.url ?? "/", "http://localhost").pathname;
	if (path === "/api/products") {
		res.writeHead(200, { "content-type": "application/json" });
		return res.end(JSON.stringify(products));
	}
	const file = normalize(join(root, path === "/" ? "index.html" : path));
	if (!file.startsWith(root)) return res.writeHead(403).end("Forbidden");
	try {
		const body = await readFile(file);
		res.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream" });
		res.end(body);
	} catch {
		res.writeHead(404, { "content-type": "text/plain" });
		res.end("Not found");
	}
}).listen(port, () => console.log(`par-shop at http://localhost:${port}/`));
