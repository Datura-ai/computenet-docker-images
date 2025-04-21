variable "RELEASE" {
    default = "0.1.3"
}

variable "IMAGE_NAME" {
    default = "daturaai/vscode-server"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["${IMAGE_NAME}:${RELEASE}"]
    args = {
        BASE_IMAGE = "nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04",
    }
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
}
