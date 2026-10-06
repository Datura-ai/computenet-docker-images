variable "VERSION" {
    default = "0.0.1"
}

target "default" {
    # The templates directory, so the Dockerfile can take lium-cluster/lium-fabric-env.py as is.
    context = ".."
    dockerfile = "lium-rdma-probe/Dockerfile"
    tags = ["daturaai/lium-rdma-probe:${VERSION}"]
    # amd64 only: every host that can carry a RoCE fabric is x86.
    platforms = ["linux/amd64"]
}
