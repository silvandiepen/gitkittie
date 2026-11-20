import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

/** A real temporary directory, removed by `cleanup()`. */
export interface TempDir {
  path: string;
  write(rel: string, content: string | Uint8Array): Promise<void>;
  cleanup(): Promise<void>;
}

export async function makeTempDir(prefix = "gks-test-"): Promise<TempDir> {
  const path = await mkdtemp(join(tmpdir(), prefix));
  return {
    path,
    async write(rel, content) {
      const target = join(path, rel);
      await mkdir(dirname(target), { recursive: true });
      await writeFile(target, content);
    },
    async cleanup() {
      await rm(path, { recursive: true, force: true });
    },
  };
}
