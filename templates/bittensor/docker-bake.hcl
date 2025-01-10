variable "VERSION" {
    default = "8.5.0"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/bittensor:${VERSION}"]
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
    args = {
        VERSION = "${VERSION}"
    }
}
