/**
 * Diff a snapshot of analyzed file content against the current project
 * files to determine which paths' graph spans are out of sync.
 *
 * Consumed by the stale-graph banner and nav-affordance gates (#22).
 *
 * A path is considered present in the snapshot only if it had an entry at
 * analysis time (i.e. it was actually analyzed). New files the user added
 * after analysis are not stale — they simply aren't in the graph yet. A
 * path that was analyzed but is now missing from `currentFiles` is stale
 * (the removal shifts nothing, but treating it as stale keeps consumers
 * from navigating to content that no longer exists).
 */
export function computeStalePaths(
  analyzedContentByPath: ReadonlyMap<string, string> | null,
  currentFiles: ReadonlyArray<{ path: string; content: string }>
): Set<string> {
  const stale = new Set<string>();
  if (!analyzedContentByPath) return stale;

  const currentByPath = new Map(currentFiles.map((f) => [f.path, f.content]));

  for (const [path, snapshot] of analyzedContentByPath) {
    const current = currentByPath.get(path);
    if (current !== snapshot) {
      stale.add(path);
    }
  }

  return stale;
}
