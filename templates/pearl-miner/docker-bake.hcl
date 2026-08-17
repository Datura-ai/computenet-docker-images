variable "IMAGE_NAME" {
    default = "daturaai/pearl-miner"
}

variable "RELEASE" {
    default = "0.3.0"
}

target "default" {
    dockerfile = "Dockerfile"
    platforms = ["linux/amd64"]
    tags = ["${IMAGE_NAME}:${RELEASE}"]
}
