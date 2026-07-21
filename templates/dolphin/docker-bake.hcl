variable "VERSION" {
    default = "0.0.4"
}

variable "BASE_IMAGE" {
    default = "nvidia/cuda:12.8.0-runtime-ubuntu22.04"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/dolphin:${VERSION}"]
    # amd64 only: the dolphinpod-worker binary ships no arm64 build.
    platforms = ["linux/amd64"]
    args = {
        BASE_IMAGE = "${BASE_IMAGE}"
    }
}
