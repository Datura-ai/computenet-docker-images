variable "PUBLISHER" {
    default = "daturaai"
}

group "default" {
    targets = [
        # Ubuntu 24.10
        "ubuntu2410-py313",
        "ubuntu2410-py311",

        # Ubuntu 24.04
        "ubuntu2404-py313",
        "ubuntu2404-py311",
        
        # Ubuntu 22.04
        "ubuntu2204-py313",
        "ubuntu2204-py311",
        "ubuntu2204-py39",
        
        # Ubuntu 20.04
        "ubuntu2004-py313",
        "ubuntu2004-py311",
        "ubuntu2004-py39",
    ]
}

target "ubuntu2410-py313" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/ubuntu:24.10-py3.13"]
    contexts = {
        scripts = "../../scripts"
    }
    args = {
        BASE_IMAGE = "ubuntu:24.10"
        PYTHON_VERSION = "3.13"
    }
}

target "ubuntu2410-py311" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/ubuntu:24.10-py3.11"]
    contexts = {
        scripts = "../../scripts"
    }
    args = {
        BASE_IMAGE = "ubuntu:24.10"
        PYTHON_VERSION = "3.11"
    }
}

target "ubuntu2404-py313" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/ubuntu:24.04-py3.13"]
    contexts = {
        scripts = "../../scripts"
    }
    args = {
        BASE_IMAGE = "ubuntu:24.04"
        PYTHON_VERSION = "3.13"
    }
}

target "ubuntu2404-py311" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/ubuntu:24.04-py3.11"]
    contexts = {
        scripts = "../../scripts"
    }
    args = {
        BASE_IMAGE = "ubuntu:24.04"
        PYTHON_VERSION = "3.11"
    }
}

target "ubuntu2204-py313" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/ubuntu:22.04-py3.13"]
    contexts = {
        scripts = "../../scripts"
    }
    args = {
        BASE_IMAGE = "ubuntu:22.04"
        PYTHON_VERSION = "3.13"
    }
}

target "ubuntu2204-py311" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/ubuntu:22.04-py3.11"]
    contexts = {
        scripts = "../../scripts"
    }
    args = {
        BASE_IMAGE = "ubuntu:22.04"
        PYTHON_VERSION = "3.11"
    }
}

target "ubuntu2204-py39" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/ubuntu:22.04-py3.9"]
    contexts = {
        scripts = "../../scripts"
    }
    args = {
        BASE_IMAGE = "ubuntu:22.04"
        PYTHON_VERSION = "3.9"
    }
}

target "ubuntu2004-py313" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/ubuntu:20.04-py3.13"]
    contexts = {
        scripts = "../../scripts"
    }
    args = {
        BASE_IMAGE = "ubuntu:20.04"
        PYTHON_VERSION = "3.13"
    }
}

target "ubuntu2004-py311" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/ubuntu:20.04-py3.11"]
    contexts = {
        scripts = "../../scripts"
    }
    args = {
        BASE_IMAGE = "ubuntu:20.04"
        PYTHON_VERSION = "3.11"
    }
}

target "ubuntu2004-py39" {
    dockerfile = "Dockerfile"
    tags = ["${PUBLISHER}/ubuntu:20.04-py3.9"]
    contexts = {
        scripts = "../../scripts"
    }
    args = {
        BASE_IMAGE = "ubuntu:20.04"
        PYTHON_VERSION = "3.9"
    }
}
