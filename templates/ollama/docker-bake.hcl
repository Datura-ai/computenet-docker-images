group "default" {
    targets = ["py312-cuda126"]
}

target "py312-cuda126" {
    contexts = {
        scripts = "../../scripts"
        proxy = "../../scripts/proxy"
    }
    dockerfile = "Dockerfile"
    args = {
        BASE_IMAGE = "daturaai/pytorch:2.6.0-py3.12-cuda12.6.0-devel-ubuntu22.04",
        TORCH = "torch==2.6.0+cu126 -f https://download.pytorch.org/whl/torch_stable.html",
        PYTHON_VERSION = "3.12"
    }
    tags = ["daturaai/ollama:cuda12.6"]
}
