// From-dev API contract cases. Run against a local relay with JS packages
// resolved from a moq checkout, not npm latest.
import { install } from "@moq/web-transport";
import { catalog } from "./catalog.ts";
import { closeAll, parseUrl } from "./lib.ts";
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
	process.exitCode = 1;
} finally {
	if (timeoutId !== undefined) clearTimeout(timeoutId);
	// A timed-out case is still awaiting; release its connections so Bun can exit.
	closeAll();
}
