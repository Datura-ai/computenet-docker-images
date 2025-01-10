variable "RELEASE" {
    default = "5.0.0"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/stable-diffusion:comfy-ui-${RELEASE}"]
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
}
