variable "PUBLISHER" {
    default = "daturaai"
}

group "default" {
    targets = ["empty-job"]
}

target "empty-job" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/empty-job:1.0.0"]
    # Lium executors are linux/amd64; publish arm64 too so local dev on Apple Silicon matches.
    platforms = ["linux/amd64", "linux/arm64"]
    args = {
        BASE_IMAGE = "alpine:3.20"
    }
}
