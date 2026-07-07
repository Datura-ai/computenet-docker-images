variable "PUBLISHER" {
    default = "daturaai"
}

group "default" {
    targets = ["empty-job"]
}

target "empty-job" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/empty-job:1.0.0"]
    args = {
        BASE_IMAGE = "alpine:3.20"
    }
}
