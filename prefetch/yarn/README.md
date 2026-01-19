# Yarn v1 Prefetch Workaround

## Why this exists

Some components require **Yarn v1**, but the **Node.js base images used in Konflux do not include it**.  
Since builds run in a **Hermeto (disconnected) environment**, Yarn cannot be installed in the Dockerfile using `dnf`, `curl`, or other network-based installers.

## Workaround

As recommended by the Konflux team, **Yarn v1 is prefetched** using a `package.json` file:

- Yarn v1 is fetched during the **prefetch step**
- The prefetched Yarn binary is made available to the build
- The **Dockerfile is updated** to use this prefetched Yarn binary

## Required Changes

- **Tekton configs**  
  Include the Yarn prefetch directory in `prefetch-input` for components that require Yarn v1.
- **Dockerfile**  
  Update the `PATH` (or reference the binary directly) to use the prefetched Yarn instead of installing it during the build.

## References

- Prefetch setup:  
  https://github.com/rh-gitops-midstream/release/tree/main/prefetch/yarn
- Example Tekton config:  
  https://github.com/rh-gitops-midstream/release/blob/main/.tekton/console-plugin-push.yaml
- Example Dockerfile:  
  https://github.com/rh-gitops-midstream/release/blob/main/containers/console-plugin/Dockerfile
