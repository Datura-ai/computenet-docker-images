variable "PUBLISHER" {
    default = "daturaai"
}

variable "IMAGE_NAME" {
    default = "redis"
}

variable "RELEASE" {
    default = "7.4.2"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/${IMAGE_NAME}:${RELEASE}"]
    args = {
        BASE_IMAGE = "${IMAGE_NAME}:${RELEASE}"
    }
}
