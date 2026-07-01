# pnpm Bootstrap via npm Prefetch

Related: [GITOPS-9932](https://redhat.atlassian.net/browse/GITOPS-9932)

The **Node.js base images used in Konflux do not include pnpm**.  
Since hermetic builds cannot install tools from the network in the Dockerfile, pnpm is bootstrapped the same way as Yarn v1 in `prefetch/yarn/`:

- Pin `pnpm` in `package.json` / `package-lock.json`
- Prefetch with Hermeto `npm` during `prefetch-dependencies`
- Install offline in the Dockerfile via `npm install --prefer-offline`

UI dependencies are prefetched separately with Hermeto from `pnpm-lock.yaml`. Konflux routes prefetch through the built-in package registry proxy (`enable-package-registry-proxy: 'true'`).

> **Note:** Konflux currently ships Hermeto 0.52.x, which expects `x-pnpm` (not `pnpm`) in `prefetch-input`. Use `x-pnpm` until the cluster image includes Hermeto with stable `pnpm` support.

Long term, pnpm should be bundled in `registry.access.redhat.com/ubi9/nodejs-22`.

## Regenerate lockfile

```bash
npm --prefix prefetch/pnpm install --package-lock-only
```

## Tekton prefetch-input

```json
[
  {"type": "npm", "path": "prefetch/pnpm"},
  {"type": "x-pnpm", "path": "./sources/argo-cd/ui"}
]
```

## References

- Yarn bootstrap: `prefetch/yarn/README.md`
- Example Dockerfile: `containers/argocd/Dockerfile`
- Hermeto pnpm docs: https://github.com/hermetoproject/hermeto/blob/main/docs/pnpm.md
