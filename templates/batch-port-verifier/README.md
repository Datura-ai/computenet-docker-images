This is the script to be loaded in the executor to check a lot of ports in one command.

## Build and Push

```bash
docker build -t daturaai/batch-port-verifier:0.0.1 .

docker push daturaai/batch-port-verifier:0.0.1
```


## Start on server
```bash
docker run  -e API_PORT={OPEN_PORT} --network=host daturaai/batch-port-verifier:0.0.1
```


## API Usage

### Start HTTP servers on ports
```bash
curl -X POST http://{EXTERNAL_IP}:{OPEN_PORT}/start-ports \
  -H "Content-Type: application/json" \
  -d '{"ports":[9000, 9001, 9002], "secret":"my_secret"}'
```
Response:
```json
{
  "status": "servers_started",
  "requested": 3,
  "started": 3,
  "failed": 0,
  "failed_ports": [],
  "active_ports": [9000, 9001, 9002]
}
```

### Stop HTTP servers
```bash
curl -X POST http://{EXTERNAL_IP}:{OPEN_PORT}/stop-ports \
  -H "Content-Type: application/json" \
  -d '{"ports":[9000, 9001]}'
```
Response:
```json
{
  "status": "servers_stopped",
  "requested": 2,
  "stopped": 2,
  "not_found": 0,
  "failed": 0,
  "active_ports": [9002]
}
```

### Health check
```bash
curl http://{EXTERNAL_IP}:{OPEN_PORT}/health
```