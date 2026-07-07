# No Idle Job

Tiny no-op image (`daturaai/no-idle`) for the Lium Miner Portal **No Idle Job** default-job preset.

Assigning a No Idle Job to a node stops Lium's own idle default jobs on it and forfeits the
node's unrented incentive, while the node stays fully rentable. The container runs nothing and
uses no GPU — the default-job launcher runs it with `sleep infinity`.

Base: `alpine:3.20`. Published as `daturaai/no-idle:1.0.0`.

## Build

```
docker buildx bake
```
