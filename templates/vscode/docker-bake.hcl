variable "RELEASE" {
    default = "0.1.1"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/vscode:${RELEASE}"]
    args = {
        BASE_IMAGE = "nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04",
    }
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
}
