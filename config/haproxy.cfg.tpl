global
    log /dev/log local0
    maxconn 4096
    user haproxy
    group haproxy
    daemon
    external-check
    insecure-fork-wanted

defaults
    log global
    mode http
    option httplog
    option dontlognull
    option redispatch
    retries 2
    timeout connect 3s
    timeout client 30s
    timeout server 30s

frontend entree
    bind *:80
    default_backend apps

backend apps
    balance roundrobin
    option httpchk
    http-check send meth GET uri /sante
    http-check expect status 200
    default-server inter 1s fall 2 rise 2
__SERVEURS__

frontend postgres_in
    bind *:5432
    mode tcp
    option tcplog
    default_backend postgres_primary
backend postgres_primary
    mode tcp
    option external-check
    external-check path "/usr/bin:/bin"
    external-check command /usr/local/bin/check_pg_primary.sh
    default-server inter 2s fall 2 rise 2
    server bdd1 192.168.63.31:5432 check
    server bdd2 192.168.63.32:5432 check backup

listen stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 5s
