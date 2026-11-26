// Transport tests do not need the app's DOM/matcher setup. Keeping them in Node
// also avoids Vite's encoded worktree-path externalization issue for jest-dom.
export default {
  test: {
    environment: 'node',
    include: ['src/lib/lineage-api.test.ts'],
  },
};
