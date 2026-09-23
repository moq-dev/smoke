// From-dev API contract cases. Run against a local relay with JS packages
// resolved from a moq checkout, not npm latest.
import { install } from "@moq/web-transport";
import { catalog } from "./catalog.ts";
import { parseUrl } from "./lib.ts";
import { live } from "./live.ts";
import { stats } from "./stats.ts";

install();

const { url, timeoutMs } = parseUrl();

let timeoutId: ReturnType<typeof setTimeout> | undefined;
const timeout = new Promise<never>((_, reject) => {
	timeoutId = setTimeout(() => reject(new Error("timed out waiting for the from-dev cases")), timeoutMs);
});

try {
	await Promise.race([
		(async () => {
			console.log("from-dev cases against", url.href);
			await live(url);
			await catalog(url);
			await stats(url);
			console.log("from-dev: ok");
		})(),
		timeout,
	]);
} catch (err) {
	console.error(`error: ${err instanceof Error ? err.message : String(err)}`);
	// Hard exit: Promise.race doesn't cancel the losing case, and its open
	// connections would otherwise keep bun alive past the timeout.
	process.exit(1);
} finally {
	if (timeoutId !== undefined) clearTimeout(timeoutId);
}
