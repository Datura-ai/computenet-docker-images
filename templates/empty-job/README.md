# Empty Job

Tiny no-op image (`daturaai/empty-job`) for the Lium Miner Portal **Empty Job** default-job preset.

Assigning it to a node stops Lium's own idle default jobs there and forgoes the node's unrented
incentive, while the node stays fully rentable. The container runs nothing and uses no GPU — the
default-job launcher runs it with `sleep infinity`.

Base: `alpine:3.20`. Published as `daturaai/empty-job:1.0.0`.

## Build

```
docker buildx bake
```
