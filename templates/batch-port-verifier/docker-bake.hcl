variable "VERSION" {
    default = "0.0.0"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/batch-port-verifier:${VERSION}"]
}