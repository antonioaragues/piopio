export type Item = { name: string; price: number; qty: number };

/** What the items cost together. */
export function total(items: Item[]): number {
	return items.reduce((sum, item) => sum + item.price * item.qty, 0);
}
