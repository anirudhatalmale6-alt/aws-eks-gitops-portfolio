# 05 Monitoring

## What is running

`kube-prometheus-stack` installs Prometheus, Alertmanager, Grafana,
node-exporter, kube-state-metrics and the Prometheus Operator. On top of that,
this project adds:

- a **ServiceMonitor** telling Prometheus to scrape the demo app
- a **PrometheusRule** with four alerts and two recording rules
- a **Grafana dashboard** stored in git as a ConfigMap

## Reaching it

```sh
make grafana      # port-forwards and prints the generated password
```

or by hand:

```sh
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Prometheus and Alertmanager the same way:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
```

**No admin password is committed.** The chart generates one into a Secret. A
password in a public repository to save one `kubectl` command is not a trade
worth making, and "it is only a demo" is exactly how real credentials end up in
git history.

**Grafana is not behind an Ingress.** Grafana on a public ALB with a generated
password is an open door that search engines find. [06-ingress-and-tls.md](06-ingress-and-tls.md)
covers publishing it properly if you want to.

## How the app's metrics get out

nginx exposes counters at `/stub_status` in its own plain-text format, which
Prometheus cannot read. The pod runs the official
`nginx-prometheus-exporter` as a **sidecar**: same pod, so it can reach
`127.0.0.1:8080`, which is the only address `/stub_status` accepts.

```
  demo-app pod
  ├── nginx      :8080   /  /healthz  /readyz  /stub_status (loopback only)
  └── metrics    :9113   /metrics                ← scraped by Prometheus
```

Verified: requesting `/stub_status` through the Service returns **403**, and the
same request over loopback inside the pod returns counters. Both are assertions
in `scripts/check_image.sh`.

## The ServiceMonitor, and the trap in it

```yaml
metadata:
  labels:
    release: kube-prometheus-stack
```

By default the chart makes the operator select only ServiceMonitors carrying the
release label of its own Prometheus. A correctly written ServiceMonitor without
that label is **ignored with no error anywhere**: no event, no log line, the
target simply never appears.

This project closes it from both ends. The chart is configured with
`serviceMonitorSelectorNilUsesHelmValues: false`, which renders an empty
selector so every namespace is watched; and the label is set anyway, so a
future chart change that reverses the default cannot break it silently.

`scripts/check_helm.sh` asserts the rendered Prometheus object really has
`serviceMonitorSelector: {}`. Without that assertion the setting could be
renamed upstream and nothing here would notice.

## The alerts

Four, in `kubernetes/apps/demo-app/monitoring.yaml`. Each has a `for` window
long enough that one bad scrape does not page anyone, and an annotation that
says what to look at first.

| Alert | Fires when | First thing to check |
|---|---|---|
| `DemoAppAbsent` | no healthy target for 5m | `kubectl -n demo get endpoints demo-app` |
| `DemoAppNoReadyReplicas` | zero ready replicas for 2m | `kubectl -n demo describe pod` for probe failures |
| `DemoAppBelowDisruptionBudget` | ready < PDB floor for 10m | usually spot reclaim; past 10m it is scheduling |
| `DemoAppPodRestarting` | >3 restarts in 15m | liveness probe timeout vs real startup time |

`DemoAppAbsent` is the one people forget to write. Every other rule is evaluated
over the app's own metrics, so if the app disappears entirely they all go quiet
and the dashboards look peaceful. `absent()` is what notices the silence.

## Recording rules

```yaml
- record: demo_app:http_requests:rate5m
  expr: sum(rate(nginx_http_requests_total{job="demo-app"}[5m]))
```

Prometheus evaluates this once per interval and stores the result, so a
dashboard panel reads one cheap series instead of recomputing a `rate()` over
raw counters on every refresh. On a dashboard with a dozen panels that is the
difference between a responsive Grafana and one that times out.

## The dashboard lives in git

`kubernetes/platform/grafana-dashboard-demo-app.yaml` is a ConfigMap labelled
`grafana_dashboard: "1"`. The Grafana sidecar watches for that label and loads
whatever JSON it contains.

The alternative, building it by clicking in the Grafana UI, stores it in
Grafana's own database, which is on a PVC. Lose the PVC and every dashboard is
gone with no record of what it contained.

Eleven panels: ready vs desired replicas, requests per second, nginx connection
states, CPU against the **request** (which is what the HPA actually scales on),
memory against the limit, restarts, and ready replicas against the
PodDisruptionBudget floor.

The datasource is a template variable, `${DS_PROMETHEUS}`, not a hardcoded uid.
A Prometheus datasource uid is generated at install time and differs between
clusters; hardcoding it is why so many downloaded dashboards open empty.
`scripts/check_dashboard.py` rejects a hardcoded uid, an empty panel list and a
panel with no query.

## What is switched off, and why

```yaml
kubeControllerManager: { enabled: false }
kubeScheduler:         { enabled: false }
kubeEtcd:              { enabled: false }
kubeProxy:             { enabled: false }
```

On EKS the control plane is managed by AWS and these components are not
reachable or scrapeable. Left enabled, they produce permanently firing
"target down" alerts.

That is worse than having no alerts. A dashboard with four alerts that are
always red teaches everyone to ignore alerts, and then the real one arrives and
nobody looks.

## Checking a target is actually being scraped

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090/targets   ->  look for job="demo-app", state UP
```

If it is not there: the Service has no `metrics` port, or the ServiceMonitor's
selector does not match the Service's labels, or the operator is not watching
that namespace. In that order.

Next: [06-ingress-and-tls.md](06-ingress-and-tls.md).
