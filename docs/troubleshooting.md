# Troubleshooting

## Debug Hermeto Prefetch Failures

To debug a Hermeto prefetch failure locally, navigate to the source/component repository and run the Hermeto container image.

For a pnpm project:

```bash
podman run --rm -it \
  -v "$PWD:$PWD:z" \
  -w "$PWD" \
  ghcr.io/hermetoproject/hermeto:latest \
  fetch-deps pnpm
```

This runs the Hermeto dependency prefetch locally using the current repository as the source.