terraform {
  required_version = ">= 1.6"
  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.60"
    }
    dynatrace = {
      source  = "dynatrace-oss/dynatrace"
      version = "~> 1.60"
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

  widget {
    timeseries_definition {
      title = "RUM page views by path"
      request {
        display_type = "bars"
        rum_query {
          index        = "rum"
          search_query = "@type:view"
          compute_query {
            aggregation = "count"
          }
          group_by {
            facet = "@view.url_path"
            limit = 10
            sort_query {
              aggregation = "count"
              order       = "desc"
            }
          }
        }
      }
    }
  }

  widget {
    timeseries_definition {
      title = "RUM Largest Contentful Paint p75 (ns)"
      request {
        display_type = "line"
        rum_query {
          index        = "rum"
          search_query = "@type:view"
          compute_query {
            aggregation = "pc75"
            facet       = "@view.largest_contentful_paint"
          }
        }
      }
    }
  }
}

# Mirrors Grafana's "Tasklog · Infrastructure" board from the k8s_cluster
# receiver copy (metrics/datadog-infra pipeline). Node/pod *usage* metrics
# deliberately ship to Elasticsearch only, and pipeline health is Prometheus
# territory - the note widget states both, same scope-note pattern as the
# Dynatrace documents.
resource "datadog_dashboard" "tasklog_infra" {
  title       = "Tasklog · Infrastructure (Terraform)"
  description = "Kubernetes cluster state from the OTel k8s_cluster receiver. Provisioned as code."
  layout_type = "ordered"

  widget {
    timeseries_definition {
      title = "Pod restarts (running total) by pod"
      request {
        q            = "max:k8s.container.restarts{*} by {pod_name}"
        display_type = "line"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Containers ready by namespace"
      request {
        q            = "sum:k8s.container.ready{*} by {kube_namespace}"
        display_type = "line"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "CPU requested vs node allocatable"
      request {
        q            = "sum:k8s.container.cpu_request{*}"
        display_type = "line"
      }
      request {
        q            = "sum:k8s.node.allocatable_cpu{*}"
        display_type = "line"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Deployments desired vs available"
      request {
        q            = "sum:k8s.deployment.desired{*} by {kube_deployment}"
        display_type = "line"
      }
      request {
        q            = "sum:k8s.deployment.available{*} by {kube_deployment}"
        display_type = "line"
      }
    }
  }

  widget {
    note_definition {
      content          = "**Scope note.** This board shows Kubernetes *cluster state* (the `k8s_cluster` receiver copy). Node and pod *usage* (CPU/memory/throttling) ships to **Elasticsearch** via the otel-agent DaemonSet, and pipeline health (collector/Vector internals) lives in **Grafana/Prometheus**. There is no Datadog Agent in this cluster by design - one OTel pipeline feeds every platform."
      background_color = "gray"
      font_size        = "14"
      text_align       = "left"
      show_tick        = false
    }
  }
}

resource "datadog_metric_tag_configuration" "request_duration_percentiles" {
  metric_name         = var.duration_metric
  metric_type         = "distribution"
  include_percentiles = true
  tags                = ["service", "env", "version", "route", "method", "status", "host"]
}
