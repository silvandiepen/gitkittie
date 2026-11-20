/** An error that maps directly to an HTTP status and a JSON `{ "error": code }` body. */
export class HttpError extends Error {
  readonly status: 400 | 403 | 404 | 409 | 412 | 413 | 416 | 500;
  readonly code: string;
  readonly extra: Record<string, unknown>;

  constructor(
    status: HttpError["status"],
    code: string,
    message?: string,
    extra: Record<string, unknown> = {},
  ) {
    super(message ?? code);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

/** Node `fs` errors carry a string `code` (ENOENT, ENOTDIR, …). */
export function errnoCode(error: unknown): string | undefined {
  if (typeof error === "object" && error !== null && "code" in error) {
    const code = (error as { code: unknown }).code;
    return typeof code === "string" ? code : undefined;
  }
  return undefined;
}
