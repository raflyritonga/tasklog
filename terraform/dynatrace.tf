provider "dynatrace" {
  dt_env_url     = var.dt_tenant_url
  dt_api_token   = var.dt_api_token
  platform_token = var.dt_platform_token
}

locals {
  dt_davis_enabled = length(var.dt_tenant_url) > 0 && length(var.dt_platform_token) > 0 && length(var.dt_actor_uuid) > 0
}

resource "dynatrace_davis_anomaly_detectors" "api_5xx_burst" {
  count       = local.dt_davis_enabled ? 1 : 0
  enabled     = true
  title       = "tasklog api 5xx burst"
  description = "5xx responses on tasklog-api exceeded the threshold. Same rule as the Grafana, Datadog and Elastic alerts, provisioned by Terraform."
  source      = "tasklog-terraform"

  analyzer {
    name = "dt.statistics.ui.anomaly_detection.StaticThresholdAnomalyDetectionAnalyzer"
    input {
      analyzer_input_field {
        key   = "query"
        value = "timeseries errors = sum(${var.dt_request_metric}, default: 0), filter: { startsWith(status, \"5\") }"
      }
      analyzer_input_field {
        key   = "threshold"
        value = "10"
      }
      analyzer_input_field {
        key   = "alertCondition"
        value = "ABOVE"
      }
      analyzer_input_field {
        key   = "alertOnMissingData"
        value = "false"
      }
      analyzer_input_field {
        key   = "violatingSamples"
        value = "3"
      }
      analyzer_input_field {
        key   = "slidingWindow"
        value = "5"
      }
      analyzer_input_field {
        key   = "dealertingSamples"
        value = "5"
      }
    }
  }

  event_template {
    properties {
      property {
        key   = "event.type"
        value = "CUSTOM_ALERT"
      }
      property {
        key   = "event.name"
        value = "tasklog api 5xx burst"
      }
      property {
        key   = "event.description"
        value = "More than 10 5xx responses across 3 of the last 5 one-minute windows on tasklog-api."
      }
    }
  }

  execution_settings {
    actor        = var.dt_actor_uuid
    query_offset = 1
  }
}
