import { expect, spyOn, test } from "bun:test";
import { Hono } from "hono";
import { operationError } from "../server/errors";

test("unexpected failures correlate a safe public reference without logging multiline SQL or secrets", async () => {
  const logged = spyOn(console, "error").mockImplementation(() => {});
  try {
    const app = new Hono();
    app.onError(operationError);
    app.get("/failure", () => {
      throw new Error(
        "Failed query: private SQL\nparams: private-secret customer@example.test",
      );
    });
    const response = await app.request("/failure");
    expect(response.status).toBe(503);
    const body = (await response.json()) as {
      code: string;
      details: { reference: string; retryable: boolean };
    };
    expect(body.code).toBe("operation_unavailable");
    expect(body.details.retryable).toBe(true);
    expect(body.details.reference).toBeTruthy();
    const diagnostics = JSON.stringify(logged.mock.calls);
    expect(diagnostics).toContain(body.details.reference);
    expect(diagnostics).not.toMatch(
      /private SQL|private-secret|customer@example/,
    );
    expect(JSON.stringify(body)).not.toMatch(
      /private SQL|private-secret|customer@example/,
    );
  } finally {
    logged.mockRestore();
  }
});
