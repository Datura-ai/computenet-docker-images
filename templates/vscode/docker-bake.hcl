variable "RELEASE" {
    default = "0.1.1"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/vscode:${RELEASE}"]
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
}
