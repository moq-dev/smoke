import { describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ConsoleMessage, Page, Request, Response } from "playwright";
import { Diagnostics, responseBody } from "./diagnostics";

describe("responseBody", () => {
	test("retains a CDN error body", () => {
		expect(responseBody(Buffer.from("upstream unavailable"))).toEqual({
			body: "dXBzdHJlYW0gdW5hdmFpbGFibGU=",
		});
	});

	test("bounds diagnostic artifacts", () => {
		expect(responseBody(Buffer.alloc(256 * 1024 + 1))).toEqual({
			bodyError: "body exceeds 262144 bytes",
		});
	});
});

test("records the failed exchange and page context", async () => {
	const handlers = new Map<string, Array<(value: never) => void>>();
	const page = {
		on(name: string, handler: (value: never) => void) {
			handlers.set(name, [...(handlers.get(name) ?? []), handler]);
		},
	} as unknown as Page;
	const emit = (name: string, value: unknown) => {
		for (const handler of handlers.get(name) ?? []) handler(value as never);
	};
	const request = {
		method: () => "GET",
		url: () => "https://cdn.jsdelivr.net/npm/@moq/watch/element/+esm",
		resourceType: () => "script",
		headers: () => ({ origin: "http://localhost:1234" }),
		failure: () => ({ errorText: "net::ERR_FAILED" }),
	} as unknown as Request;
	const response = {
		request: () => request,
		url: request.url,
		status: () => 503,
		statusText: () => "Service Unavailable",
		headers: () => ({ "content-type": "text/plain" }),
		body: async () => Buffer.from("upstream unavailable"),
	} as unknown as Response;
	const message = {
		type: () => "error",
		text: () => "blocked by CORS policy",
		location: () => ({ url: request.url(), lineNumber: 0, columnNumber: 0 }),
	} as unknown as ConsoleMessage;

	const diagnostics = new Diagnostics(page, "subscribe", "jsdelivr", "http://localhost:1234/");
	emit("request", request);
	emit("response", response);
	emit("requestfailed", request);
	emit("console", message);
	emit("pageerror", new Error("module load failed"));

	const dir = await mkdtemp(join(tmpdir(), "smoke-diagnostics-"));
	try {
		const path = await diagnostics.write(dir, "failure", new Error("goto failed"));
		const artifact = JSON.parse(await readFile(path, "utf8"));
		expect(artifact.requests[0]).toMatchObject({
			url: request.url(),
			failure: "net::ERR_FAILED",
			response: {
				status: 503,
				headers: { "content-type": "text/plain" },
				body: "dXBzdHJlYW0gdW5hdmFpbGFibGU=",
			},
		});
		expect(artifact.console[0].text).toBe("blocked by CORS policy");
		expect(artifact.pageErrors[0]).toContain("module load failed");
		expect(artifact.error).toContain("goto failed");
	} finally {
		await rm(dir, { recursive: true });
	}
});
