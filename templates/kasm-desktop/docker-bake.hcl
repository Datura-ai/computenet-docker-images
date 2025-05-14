variable "IMAGE_NAME" {
    default = "daturaai/kasm-docker"
}

variable "RELEASE" {
    default = "latest"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["${IMAGE_NAME}:${RELEASE}"]
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
}
