variable "VERSION" {
    default = "0.0.4"
}

variable "BASE_IMAGE" {
    default = "daturaai/pytorch:2.12.0-py3.12-cuda12.8-devel-ubuntu24.04-dind"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/lium-cluster:${VERSION}"]
    # amd64 only: the base carries CUDA and the RDMA userspace, neither of which ships arm64 here.
    platforms = ["linux/amd64"]
    args = {
        BASE_IMAGE = "${BASE_IMAGE}"
    }
}
