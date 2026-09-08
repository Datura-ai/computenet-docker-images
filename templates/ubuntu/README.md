## Targets

- Ubuntu 24.04 with Python 3.13 or 3.11 (`docker buildx bake --print` lists them).
- The Ubuntu 20.04 targets were removed on 8 Sep 2026: focal is end-of-life and the deadsnakes PPA no longer publishes Python for it, so they could not be rebuilt. The `daturaai/ubuntu:20.04-*` tags already on Docker Hub are unchanged.

## Build Instructions

- To build with the default options, simply run `docker buildx bake`.
- To build a specific target, use `docker buildx bake <target>`.
- To specify the platform, use `docker buildx bake <target> --set <target>.platform=linux/amd64`.

Example:
```bash
docker buildx bake ubuntu2404-py313 --set ubuntu2404-py313.platform=linux/amd64
```

## Exposed Ports

- 22/tcp (SSH)
