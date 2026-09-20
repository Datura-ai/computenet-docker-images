group "default" {
    targets = ["full-version", "light-version", "dev"]
}

# The one target scripts/build-smoke.sh builds and boots when this template changes: the light image (no checkpoint
# downloads); the GPU serve check is smoke/template_serve_probe.sh on a GPU host (README).
group "smoke" {
    targets = ["light-version"]
}

target "base" {
    dockerfile = "Dockerfile"
    args = {
        # CUDA 12.8 base and cu128 wheels: Blackwell (sm_100/sm_120) plus everything the cu124 build ran on (DAH-3704)
        BASE_IMAGE = "daturaai/pytorch:2.7.0-py3.12-cuda12.8.0-devel-ubuntu22.04",
        TORCH = "torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0 --index-url https://download.pytorch.org/whl/cu128",
        XFORMERS = "xformers==0.0.30 --index-url https://download.pytorch.org/whl/cu128",
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
