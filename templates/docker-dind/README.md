# Running the Docker Image

To run the Docker image, use the following command:

```bash
 docker run -d --gpus all --runtime=sysbox-runc \
 --rm --name=dind-test -e PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMo32AY0vFK7g5FBIBcyPdxaxSEM5rEc0kEzMVveA9b+ waris0609@outlook.com' -p 2023:22 daturaai/dind:0.0.0

 docker run --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi
```