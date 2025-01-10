variable "RELEASE" {
    default = "1.2.1"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/oobabooga:${RELEASE}"]
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
}
