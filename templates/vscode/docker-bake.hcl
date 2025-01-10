variable "RELEASE" {
    default = "0.1.0"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/vscode:${RELEASE}"]
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
}
