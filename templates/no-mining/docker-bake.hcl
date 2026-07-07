variable "PUBLISHER" {
    default = "daturaai"
}

group "default" {
    targets = ["no-mining"]
}

target "no-mining" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/no-mining:1.0.0"]
    args = {
        BASE_IMAGE = "alpine:3.20"
    }
}
