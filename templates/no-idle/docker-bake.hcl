variable "PUBLISHER" {
    default = "daturaai"
}

group "default" {
    targets = ["no-idle"]
}

target "no-idle" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/no-idle:1.0.0"]
    args = {
        BASE_IMAGE = "alpine:3.20"
    }
}
