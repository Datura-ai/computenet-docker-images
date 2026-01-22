variable "IMAGE_NAME" {
    default = "daturaai/lium-validator"
}

variable "RELEASE" {
    default = "latest"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["${IMAGE_NAME}:${RELEASE}"]
    platforms = ["linux/amd64"]
}
