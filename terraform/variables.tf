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

variable "elastic_password" {
  type      = string
  sensitive = true
  default   = ""
}

variable "elastic_es_endpoint" {
  type    = string
  default = "http://localhost:9200"
}

variable "elastic_kibana_endpoint" {
  type    = string
  default = "http://kibana.tasklog-demo.orb.local"
}

variable "dt_tenant_url" {
  type    = string
  default = ""
}

variable "dt_api_token" {
  type      = string
  sensitive = true
  default   = ""
}

variable "dt_request_metric" {
  type    = string
  default = "http.server.request.count"
}
