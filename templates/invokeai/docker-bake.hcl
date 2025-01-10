variable "RELEASE" {
    default = "3.3.0"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/stable-diffusion:invoke-${RELEASE}"]
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
}
