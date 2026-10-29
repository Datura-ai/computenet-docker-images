variable "VERSION" {
    default = "0.0.10-cuda13.0"
}

variable "BASE_IMAGE" {
    default = "daturaai/pytorch:2.12.0-py3.12-cuda13.0.2-devel-ubuntu24.04-dind"
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

# V100 fabrics (sm_70): torch cu130 starts at sm_75, so torchrun failed "no kernel image is available" on every rank.
# The cu126 -lium1 PyTorch base is the only torch build with sm_70 kernels. Push that base first.
target "cuda126" {
    inherits = ["default"]
    tags = ["daturaai/lium-cluster:0.0.10-cuda12.6"]
    args = {
        BASE_IMAGE = "daturaai/pytorch:2.12.0-py3.12-cuda12.6-devel-ubuntu24.04-dind-lium1"
    }
}
