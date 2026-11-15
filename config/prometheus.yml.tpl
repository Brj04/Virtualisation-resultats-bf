global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:

  # Prometheus lui-m?me
  - job_name: prometheus
    static_configs:
      - targets: ['__PROMETHEUS_IP__:9090']
        labels:
          instance: obs

  # M?triques syst?me de toutes les machines
  - job_name: node_exporter
    static_configs:
__NODE_EXPORTER_TARGETS__

  # M?triques HAProxy des r?partiteurs
  - job_name: haproxy
    metrics_path: /metrics
    static_configs:
__HAPROXY_TARGETS__
