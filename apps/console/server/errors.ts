import type { ErrorHandler } from "hono";
import { randomUUID } from "node:crypto";

export class OperationError extends Error {
  constructor(
    public status: 400 | 401 | 403 | 404 | 409 | 413 | 429 | 502 | 503,
    public code: string,
    message: string,
    public details?: { reference: string; retryable: boolean },
  ) {
    super(message);
  }
}

export function operationFailure(error: unknown): OperationError {
  if (error instanceof OperationError) return error;
  const reference = randomUUID();
  // Stack frames identify the failing operation without logging exception
  // messages, SQL parameters, payment bodies or credentials.
  const frames = error instanceof Error ? error.stack?.split("\n").filter(line => /^\s+at\s/.test(line)).slice(0, 4).map(line => line.trim().slice(0, 240)) : undefined;
  console.error("[console] operation failed", JSON.stringify({ reference, name: error instanceof Error ? error.name : "UnknownError", frames }));
  return new OperationError(503, "operation_unavailable", "This request could not finish. Please retry shortly.", { reference, retryable: true });
}

export const operationError: ErrorHandler = (error, c) => {
  const failure = operationFailure(error);
  return c.json({ error: failure.message, code: failure.code, ...(failure.details ? { details: failure.details } : {}) }, failure.status);
};
