variable "dd_api_key" {
  type      = string
  sensitive = true
}

variable "dd_app_key" {
  type      = string
  sensitive = true
}

variable "dd_site" {
  type    = string
  default = "datadoghq.com"
}

variable "service" {
  type    = string
  default = "tasklog-api"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "notify" {
  type    = string
  default = "here"
}

variable "request_metric" {
  type    = string
  default = "http.server.request.count"
}

variable "duration_metric" {
  type    = string
  default = "http.server.request.duration"
}
