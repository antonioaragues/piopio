// Lists the shop's products.
async function load() {
	const res = await fetch("/api/items");
	const products = await res.json();
	const list = document.getElementById("products");
	for (const p of products) {
		const li = document.createElement("li");
		li.textContent = `${p.name} · ${p.price.toFixed(2)} €`;
		list.append(li);
	}
	document.getElementById("status").textContent = `${products.length} products`;
}

load().catch((error) => {
	console.error("Couldn't load the products:", error.message);
	document.getElementById("status").textContent = "Couldn't load the products.";
});
