variable "VERSION" {
    default = "0.0.1"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["daturaai/batch-port-verifier:${VERSION}"]
}