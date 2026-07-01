# pnpm Bootstrap via npm Prefetch

Related: [GITOPS-9932](https://redhat.atlassian.net/browse/GITOPS-9932)

The **Node.js base images used in Konflux do not include pnpm**.  
Since hermetic builds cannot install tools from the network in the Dockerfile, pnpm is bootstrapped the same way as Yarn v1 in `prefetch/yarn/`:

- Pin `pnpm` in `package.json` / `package-lock.json`
- Prefetch with Hermeto `npm` during `prefetch-dependencies`
- Install offline in the Dockerfile via `npm install --prefer-offline`

UI dependencies are prefetched separately with Hermeto from `pnpm-lock.yaml`. Konflux routes prefetch through the built-in package registry proxy (`enable-package-registry-proxy: 'true'`).

Hermeto `inject-files` patches `pnpm-lock.yaml` during prefetch. The Dockerfile writes `.npmrc` to point at `/cachi2/output/deps/pnpm/` and runs `pnpm install --offline` for hermetic builds.

> **Note:** Konflux currently ships Hermeto 0.52.x, which expects `x-pnpm` (not `pnpm`) in `prefetch-input`. Stable `pnpm` support is in Hermeto 0.57.0 and will reach Konflux after [build-definitions#3606](https://github.com/konflux-ci/build-definitions/pull/3606) is merged and rolled out (no ETA yet). Use `x-pnpm` until then — same backend, only the type name differs.

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
