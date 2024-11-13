## Build Instructions

- To build with the default options, simply run `docker buildx bake`.
- To build a specific target, use `docker buildx bake <target>`.
- To specify the platform, use `docker buildx bake <target> --set <target>.platform=linux/amd64`.

Example:
```bash
docker buildx bake ubuntu2410-py312 --set ubuntu2410-py312.platform=linux/amd64
```

## Exposed Ports

- 22/tcp (SSH)
