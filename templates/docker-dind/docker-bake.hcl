variable "VERSION" {
    default = "0.0.0"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/dind:${VERSION}"]
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
    args = {
        VERSION = "${VERSION}"
    }
}