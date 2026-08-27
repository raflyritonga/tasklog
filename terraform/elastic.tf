provider "elasticstack" {
  elasticsearch {
    endpoints = [var.elastic_es_endpoint]
    username  = "elastic"
    password  = var.elastic_password
  }
  kibana {
    endpoints = [var.elastic_kibana_endpoint]
    username  = "elastic"
    password  = var.elastic_password
  }
}

resource "elasticstack_kibana_alerting_rule" "api_5xx_burst" {
  name         = "tasklog api 5xx burst"
  consumer     = "logs"
  rule_type_id = ".es-query"
  interval     = "1m"
  enabled      = true

  params = jsonencode({
    searchType                 = "esQuery"
    index                      = ["logs-tasklog*"]
    timeField                  = "@timestamp"
    esQuery                    = jsonencode({ query = { bool = { filter = [{ range = { "http.response.status_code" = { gte = 500 } } }] } } })
    size                       = 100
    threshold                  = [10]
    thresholdComparator        = ">"
    timeWindowSize             = 5
    timeWindowUnit             = "m"
    aggType                    = "count"
    groupBy                    = "all"
    excludeHitsFromPreviousRun = true
  })
}

resource "elasticstack_kibana_alerting_rule" "error_burst_by_source_ip" {
  name         = "tasklog error burst from a single source ip"
  consumer     = "logs"
  rule_type_id = ".es-query"
  interval     = "1m"
  enabled      = true

  params = jsonencode({
    searchType                 = "esQuery"
    index                      = ["logs-tasklog*"]
    timeField                  = "@timestamp"
    esQuery                    = jsonencode({ query = { bool = { filter = [{ range = { "http.response.status_code" = { gte = 500 } } }] } } })
    size                       = 100
    threshold                  = [5]
    thresholdComparator        = ">"
    timeWindowSize             = 5
    timeWindowUnit             = "m"
    aggType                    = "count"
    groupBy                    = "top"
    termField                  = "client.ip"
    termSize                   = 5
    excludeHitsFromPreviousRun = true
  })
}
