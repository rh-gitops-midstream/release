# Red Hat Openshift GitOps Dex

This repo holds configurations to build upstream Dex via Konflux CI for Red Hat Openshift GitOps.

## How to update Dex version?

Use `make update-dex ref=<commit-or-tag>` target to update dex submodule. 

Example:
```bash
make update-dex ref=v2.41.1
```

After running the target, verify the changes and commit them.

## How to validate changes locally?

Run `make build-plugin` target to build image locally.

```bash
make build-plugin
```

# TODO: This is no longer valid. Update the docs
## How to add/update prefetch RPM dependencies?

Configurations for prefetching RPMs for hermetic (disconnected) builds are located in the [deps](./deps) directory. For detailed instructions on adding a new RPM dependency, refer to the [Konflux documentation](https://konflux-ci.dev/docs/how-tos/configuring/prefetching-dependencies/#rpm).

> [!TIP]  
> After modifying any RPM dependency files, use the helper target `make generate-rpms-lock` to regenerate the `rpms.lock.yaml` file required by Konflux.