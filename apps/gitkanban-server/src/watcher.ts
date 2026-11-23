import { watch, type FSWatcher } from "node:fs";
import { sep } from "node:path";
import { isHiddenRelPath } from "./paths.js";

export interface ChangeListener {
  /** Coalesced root-relative paths that changed since the last batch. */
  onChange(paths: string[]): void;
  /** The underlying watcher failed; the listener should end its stream so clients reconnect. */
  onClose(): void;
}

/**
 * One recursive `fs.watch` on the root, shared by every SSE client. Started on the first
 * subscriber, closed when the last one leaves. Changes are debounced and de-duplicated.
 */
export class SharedWatcher {
  private readonly root: string;
  private readonly listeners = new Set<ChangeListener>();
  private watcher: FSWatcher | null = null;
  private pending = new Set<string>();
  private timer: NodeJS.Timeout | null = null;
  private batchStartedAt = 0;

  /**
   * @param debounceMs quiet period before a batch is emitted.
   * @param maxWaitMs upper bound on how long a batch is held during continuous churn
   *   (e.g. a sync tool writing many files), so clients aren't starved of events.
   */
  constructor(
    root: string,
    private readonly debounceMs = 150,
    private readonly maxWaitMs = 1000,
  ) {
    this.root = root;
  }

  get subscriberCount(): number {
    return this.listeners.size;
  }

  get isWatching(): boolean {
    return this.watcher !== null;
  }

  /** Adds a listener; returns its unsubscribe function (idempotent). */
  subscribe(listener: ChangeListener): () => void {
    this.listeners.add(listener);
    if (!this.watcher) {
      this.start();
    }
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) {
        this.stop();
      }
    };
  }

  private start(): void {
    const watcher = watch(this.root, { recursive: true }, (_event, filename) => {
      if (filename === null) {
        return;
      }
      const rel = filename.toString().split(sep).join("/");
      if (rel === "" || isHiddenRelPath(rel)) {
        return;
      }
      this.pending.add(rel);
      this.schedule();
    });
    watcher.on("error", (error) => {
      console.error("[gitkanban-server] watcher error:", error);
      const listeners = [...this.listeners];
      this.listeners.clear();
      this.stop();
      for (const listener of listeners) {
        listener.onClose();
      }
    });
    this.watcher = watcher;
  }

  private schedule(): void {
    const now = Date.now();
    if (this.timer) {
      clearTimeout(this.timer);
    } else {
      this.batchStartedAt = now;
    }
    const remaining = this.batchStartedAt + this.maxWaitMs - now;
    this.timer = setTimeout(() => this.flush(), Math.max(0, Math.min(this.debounceMs, remaining)));
  }

  private flush(): void {
    this.timer = null;
    if (this.pending.size === 0) {
      return;
    }
    const paths = [...this.pending].sort();
    this.pending = new Set();
    for (const listener of this.listeners) {
      listener.onChange(paths);
    }
  }

  private stop(): void {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    this.pending.clear();
    this.watcher?.close();
    this.watcher = null;
  }
}
