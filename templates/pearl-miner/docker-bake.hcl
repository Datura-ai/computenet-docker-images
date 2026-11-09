variable "IMAGE_NAME" {
    default = "daturaai/pearl-miner"
}

variable "RELEASE" {
    default = "0.6.0"
}

# DAH-6084: WildRig Multi build for the Pearl benchmark. Pin = official release tarball + its sha256 (Dockerfile verifies it).
variable "WILDRIG_VERSION" {
    default = "0.51.9"
}

variable "WILDRIG_SHA256" {
    default = "7444c6c48b70006c2ec045bd69a37393c2fc293c7e47cdf561c9561408d5bb44"
}

target "default" {
    dockerfile = "Dockerfile"
    platforms = ["linux/amd64"]
    tags = ["${IMAGE_NAME}:${RELEASE}"]
}

target "wildrig" {
    inherits = ["default"]
    args = {
        PEARL_MINER = "wildrig"
        WILDRIG_VERSION = "${WILDRIG_VERSION}"
        WILDRIG_SHA256 = "${WILDRIG_SHA256}"
    }
    tags = ["${IMAGE_NAME}:${RELEASE}-wildrig-${WILDRIG_VERSION}"]
}

# CI builds the first smoke target: the WildRig build is the one with new download + checksum steps.
group "smoke" {
    targets = ["wildrig"]
}
