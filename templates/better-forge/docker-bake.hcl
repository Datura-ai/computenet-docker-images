group "default" {
    targets = ["light"]
}

target "light" {
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
    dockerfile = "Dockerfile"
    args = {
        BASE_IMAGE = "daturaai/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04",
        PYTHON_VERSION = "3.11"
    }
    tags = ["daturaai/better-forge:light"]
}