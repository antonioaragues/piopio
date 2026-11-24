import { total, type Item } from "./cart.js";

export function receipt(items: Item[]): string {
	const lines = items.map((item) => `${item.qty} × ${item.name}`);
	return [...lines, `Total: ${total(items).toFixed(2)}`].join("\n");
}
