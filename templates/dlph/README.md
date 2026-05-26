# Dolphin worker DinD image

This image is based on the DinD template and starts the Dolphin worker bootstrap
from an embedded worker script.

## Runtime configuration

No download link is required for the baked path.

```bash
docker run -d --gpus all --runtime=sysbox-runc \
  --name dlph-test \
  -e DOLPHIN_WATCHTOWER_PORT=20000 \
  -p 20000:20000 \
  daturaai/dlph:0.0.2
```

`DOLPHIN_WATCHTOWER_PORT` defaults to `20000`.
Set `DOWNLOAD_LINK_B64` or `DOWNLOAD_LINK` only when you want to override the
embedded worker script with a freshly generated bootstrap link.

## Build

```bash
docker buildx bake --allow=fs.read="$(cd ../.. && pwd)/scripts" --push
```
