variable "VERSION" {
    default = "0.0.2"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/dlph:${VERSION}"]
    platforms = ["linux/amd64"]
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
    args = {
        VERSION = "${VERSION}"
    }
}
