provider "dynatrace" {
  dt_env_url   = var.dt_tenant_url
  dt_api_token = var.dt_api_token
}

locals {
  dt_enabled = length(var.dt_tenant_url) > 0 && length(var.dt_api_token) > 0
}

resource "dynatrace_metric_events" "api_5xx_burst" {
  count   = local.dt_enabled ? 1 : 0
  enabled = true
  summary = "tasklog api 5xx burst"

  event_template {
    title       = "tasklog api 5xx burst"
    description = "5xx responses on tasklog-api exceeded the threshold. Same rule as the Grafana, Datadog and Elastic alerts, provisioned by Terraform."
    event_type  = "CUSTOM_ALERT"
    davis_merge = true
  }

  query_definition {
    type            = "METRIC_SELECTOR"
    metric_selector = "${var.dt_request_metric}:filter(prefix(\"status\",\"5\")):splitBy():sum"
  }

  model_properties {
    type              = "STATIC_THRESHOLD"
    threshold         = 10
    alert_condition   = "ABOVE"
    alert_on_no_data  = false
    samples           = 5
    violating_samples = 3
    dealerting_samples = 5
  }
}
