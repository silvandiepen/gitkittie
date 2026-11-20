/**
 * Decodes an RFC 2047 encoded-word (`=?utf-8?q?...?=` / `=?utf-8?b?...?=`). Tailscale uses
 * Q-encoding for non-ASCII values in `Tailscale-User-Name`. Plain values pass through.
 */
export function decodeHeaderWord(value: string): string {
  const match = /^=\?([^?]+)\?([qQbB])\?([^?]*)\?=$/.exec(value.trim());
  if (!match) {
    return value;
  }
  const [, charset = "utf-8", encoding = "q", text = ""] = match;
  if (charset.toLowerCase() !== "utf-8") {
    return value;
  }
  if (encoding.toLowerCase() === "b") {
    return Buffer.from(text, "base64").toString("utf8");
  }
  const bytes: number[] = [];
  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    if (char === "_") {
      bytes.push(0x20);
    } else if (char === "=" && /^[0-9A-Fa-f]{2}$/.test(text.slice(i + 1, i + 3))) {
      bytes.push(parseInt(text.slice(i + 1, i + 3), 16));
      i += 2;
    } else {
      bytes.push(text.charCodeAt(i));
    }
  }
  return Buffer.from(bytes).toString("utf8");
}
