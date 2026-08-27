terraform {
  required_version = ">= 1.6"
  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.60"
    }
    elasticstack = {
      source  = "elastic/elasticstack"
      version = "~> 0.11"
    }
  }
}

provider "datadog" {
  api_key = var.dd_api_key
  app_key = var.dd_app_key
  api_url = "https://api.${var.dd_site}/"
}

resource "datadog_monitor" "api_error_ratio" {
  name    = "tasklog api 5xx ratio above 5 percent"
  type    = "query alert"
  message = "More than 5% of tasklog-api requests are failing. Same rule as the Grafana alert, provisioned by Terraform. @${var.notify}"

  query = "sum(last_5m):sum:${var.request_metric}{service:${var.service},status:5*}.as_count() / sum:${var.request_metric}{service:${var.service}}.as_count() * 100 > 5"

  monitor_thresholds {
    critical = 5
    warning  = 2
  }

  notify_no_data    = false
  renotify_interval = 0
  tags              = ["env:${var.env}", "project:tasklog", "managed-by:terraform"]
}

resource "datadog_monitor" "api_latency" {
  name    = "tasklog api p95 latency above 800ms"
  type    = "query alert"
  message = "tasklog-api p95 latency is above 800ms. @${var.notify}"

  query = "percentile(last_5m):p95:${var.duration_metric}{service:${var.service}} > 0.8"

  monitor_thresholds {
    critical = 0.8
  }

  notify_no_data    = false
  renotify_interval = 0
  tags              = ["env:${var.env}", "project:tasklog", "managed-by:terraform"]
}

resource "datadog_dashboard" "tasklog" {
  title       = "Tasklog · Application (Terraform)"
  description = "Golden signals plus business dimensions from span tags. Provisioned as code."
  layout_type = "ordered"

  widget {
    timeseries_definition {
      title = "Request rate by route"
      request {
        q            = "sum:${var.request_metric}{service:${var.service}} by {route}.as_rate()"
        display_type = "line"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "5xx responses by route"
      request {
        q            = "sum:${var.request_metric}{service:${var.service},status:5*} by {route}.as_count()"
        display_type = "bars"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "p95 latency"
      request {
        q            = "p95:${var.duration_metric}{service:${var.service}}"
        display_type = "line"
      }
    }
  }

  widget {
    log_stream_definition {
      title           = "Error logs"
      query           = "service:${var.service} status:error"
      indexes         = ["main"]
      columns         = ["host", "service", "@route", "@status", "@trace_id"]
      message_display = "expanded-md"
    }
  }
}
