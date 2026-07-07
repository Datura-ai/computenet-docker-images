variable "VERSION" {
    default = "0.0.1"
}

variable "BASE_IMAGE" {
    default = "nvidia/cuda:12.8.0-runtime-ubuntu22.04"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/dolphin:${VERSION}"]
    args = {
        BASE_IMAGE = "${BASE_IMAGE}"
    }
}
