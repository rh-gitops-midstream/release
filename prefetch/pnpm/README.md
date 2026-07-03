# pnpm Bootstrap via npm Prefetch

Related: [GITOPS-9932](https://redhat.atlassian.net/browse/GITOPS-9932)

The **Node.js base images used in Konflux do not include pnpm**.  
Since hermetic builds cannot install tools from the network in the Dockerfile, pnpm is bootstrapped the same way as Yarn v1 in `prefetch/yarn/`:

- Pin `pnpm` in `package.json` / `package-lock.json`
- Prefetch with Hermeto `npm` during `prefetch-dependencies`
- Install offline in the Dockerfile via `npm install --prefer-offline`

Long term, pnpm should be bundled in `registry.access.redhat.com/ubi9/nodejs-22`.

## Hermetic UI dependency prefetch (future)

UI dependencies can be prefetched with Hermeto `pnpm` from `pnpm-lock.yaml` once Konflux ships **Hermeto 0.57.0** .

When 0.57.0 is available, set `hermetic: true` and add to `prefetch-input`:

```json
[
  {"type": "npm", "path": "prefetch/pnpm"},
  {"type": "pnpm", "path": "./sources/argo-cd/ui"}
]
```
## Regenerate lockfile

```bash
npm --prefix prefetch/pnpm install --package-lock-only
```

## Tekton prefetch-input (current)

```json
{"type": "npm", "path": "prefetch/pnpm"}
```

## References

- Yarn bootstrap: `prefetch/yarn/README.md`
- Example Dockerfile: `containers/argocd/Dockerfile`
- Hermeto pnpm docs: https://github.com/hermetoproject/hermeto/blob/main/docs/pnpm.md
