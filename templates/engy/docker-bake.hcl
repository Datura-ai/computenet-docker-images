variable "VERSION" {
    default = "0.0.9"
}

variable "BASE_IMAGE" {
    default = "nvidia/cuda:13.0.0-devel-ubuntu24.04"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/engy:${VERSION}"]
    # amd64 only: sglang and the engy miner ship no arm64 build.
    platforms = ["linux/amd64"]
    args = {
        BASE_IMAGE = "${BASE_IMAGE}"
    }
}
