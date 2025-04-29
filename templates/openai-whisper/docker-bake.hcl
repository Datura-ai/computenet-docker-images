variable "RELEASE" {
    default = "latest"
}

variable "IMAGE_NAME" {
    default = "daturaai/whisper"
}

target "default" {
    dockerfile = "Dockerfile"
    tags = ["${IMAGE_NAME}:${RELEASE}"]
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
