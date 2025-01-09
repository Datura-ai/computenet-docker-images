variable "RELEASE" {
    default = "2.4.0"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/stable-diffusion:fast-stable-diffusion-${RELEASE}"]
    contexts = {
        scripts = "../../scripts"
    }
}
