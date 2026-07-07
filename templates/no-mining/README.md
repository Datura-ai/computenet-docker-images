# No Idle Mining

Tiny no-op image (`daturaai/no-mining`) for the Lium Miner Portal **No Idle Mining** default-job preset.

Assigning it to a node stops Lium's own idle default jobs there and forgoes the node's unrented
incentive, while the node stays fully rentable. The container runs nothing and uses no GPU — the
default-job launcher runs it with `sleep infinity`.

Base: `alpine:3.20`. Published as `daturaai/no-mining:1.0.0`.

## Build

```
docker buildx bake
```
