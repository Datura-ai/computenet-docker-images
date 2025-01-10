variable "RELEASE" {
  default = "1.0.3"
}

target "default" {
  dockerfile = "Dockerfile"
  tags = ["daturaai/tensorflow:${RELEASE}"]
  contexts = {
    scripts = "../../scripts"
    proxy = "../../scripts/proxy"
  }
}
