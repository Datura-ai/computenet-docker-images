variable "VERSION" {
    default = "0.0.2"
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