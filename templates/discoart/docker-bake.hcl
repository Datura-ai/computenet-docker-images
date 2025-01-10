variable "IMAGE_NAME" {
    default = "daturaai/discoart"
}

variable "RELEASE" {
    default = "0.0.0"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["${IMAGE_NAME}:${RELEASE}"]
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
}
