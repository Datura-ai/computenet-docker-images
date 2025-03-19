group "default" {
    targets = ["full-version", "light-version", "dev"]
}

target "base" {
    dockerfile = "Dockerfile"
    args = {
        BASE_IMAGE = "daturaai/pytorch:2.6.0-py3.12-cuda12.6.0-devel-ubuntu22.04",
        TORCH = "torch==2.6.0 -f https://download.pytorch.org/whl/torch_stable.html",
        PYTHON_VERSION1 = "3.12"
    }
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
}

target "full-version" {
    inherits = ["base"]
    args = {
        INCLUDE_MODELS = "true"
    }
    tags = ["daturaai/better-comfyui:full"]
}

target "light-version" {
    inherits = ["base"]
    args = {
        INCLUDE_MODELS = "false"
    }
    tags = ["daturaai/better-comfyui:light"]
}

target "dev" {
    inherits = ["base"]
    args = {
        INCLUDE_MODELS = "false"
    }
    tags = ["daturaai/better-comfyui:dev"]
}