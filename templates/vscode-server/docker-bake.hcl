variable "RELEASE" {
    default = "0.1.2"
}

variable "IMAGE_NAME" {
    default = "daturaai/vscode-server"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["${IMAGE_NAME}:${RELEASE}"]
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
}
