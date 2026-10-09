# 04 GitOps with Argo CD

## The distinction worth being able to state

A pipeline that ends in `kubectl apply` is **push** deployment. CI holds cluster
credentials, and the cluster's actual state is whatever the last successful job
left behind. Drift is invisible: somebody edits a Deployment by hand at 2am and
nothing ever notices.

GitOps is **pull**. An agent inside the cluster watches a git repository and
continuously makes the cluster match it. CI never touches the cluster at all.

In this project:

```
  push to app/**
       │
       ▼
  build-image.yml ── builds, pushes to ECR as :sha-abc12345
       │
       ├─ writes that tag into kubernetes/apps/demo-app/kustomization.yaml
       ├─ writes it into the ConfigMap too, so the page cannot lie about
       │  which build it is
       └─ commits and pushes
              │
              ▼  (CI stops here. It has no kubeconfig.)
              │
         Argo CD polls the repo
              │
              ▼
         Deployment rolls
```

Three consequences:

1. **`git log` on `kustomization.yaml` is the deployment history**, complete and
   accurate, because there is no other path by which the running image can
   change.
2. **A rollback is `git revert`.** No pipeline run, no credentials.
3. **A compromised CI workflow cannot deploy to the cluster**, because it has
   no way to reach it.

## App of apps

One Application is applied by hand. It points at
`kubernetes/argocd/applications/`, so everything else arrives by adding a file
to that directory.

```
root (applied once by scripts/deploy.sh)
 └── kubernetes/argocd/applications/
      ├── 00-platform.yaml                      wave -20
      ├── 10-aws-load-balancer-controller.yaml  wave -10
      ├── 11-metrics-server.yaml                wave -10
      ├── 20-monitoring.yaml                    wave   0
      └── 30-demo-app.yaml                      wave  10
```

## Sync waves, and why they are not cosmetic

Argo CD sorts resources by `argocd.argoproj.io/sync-wave`, lowest first, and
waits for each wave to be Healthy before starting the next.

| Wave | What | Why there |
|---|---|---|
| -20 | platform | the gp3 StorageClass, so volumes can be provisioned |
| -10 | ALB controller, metrics-server | an Ingress is inert without a controller; an HPA is inert without metrics-server |
| 0 | kube-prometheus-stack | installs the ServiceMonitor and PrometheusRule **CRDs** |
| 10 | demo-app | **uses** those CRDs |

Without the waves, Argo CD applies everything at once, demo-app's
ServiceMonitor is rejected with `no matches for kind "ServiceMonitor"`, and the
Application sits Degraded.

It usually recovers on retry, and that is the dangerous part: the ordering bug
is invisible on a good day and only shows up the day the retry budget runs out.
`scripts/check_sync_waves.py` asserts the ordering so it cannot regress.

## Self-heal

Every Application sets:

```yaml
syncPolicy:
  automated:
    prune: true      # delete what was removed from git
    selfHeal: true   # revert what was changed in the cluster
```

`selfHeal` is the line that makes "we use GitOps" true rather than aspirational.
Try it:

```sh
kubectl -n demo scale deployment demo-app --replicas=1
# wait a moment
kubectl -n demo get deployment demo-app
# back to 3
```

Two places where self-heal has to be told to stand down, both in the manifests
with the reason written next to them:

- **The HPA owns `spec.replicas`.** Git says 3; after a scale-up the cluster
  says 7. Without an `ignoreDifferences` entry on `/spec/replicas`, Argo CD and
  the HPA fight on every reconcile loop.
- **The Prometheus operator writes a `caBundle`** into its own webhook
  configuration at runtime. Git cannot know that value, so Argo CD would wipe it
  and break admission.

## The AppProject

Every Application belongs to the `portfolio` project rather than `default`.
`default` permits any source repository, any destination namespace and any
resource kind, which means one mistyped `repoURL` in a pull request is enough to
sync somebody else's manifests into this cluster.

`portfolio` allows this repository plus three named chart registries, four
namespaces, and a short explicit list of cluster-scoped kinds. A chart that
suddenly wants to create a `ClusterRoleBinding` nobody reviewed fails to sync
and says so.

`orphanedResources.warn: true` flags anything living in those namespaces that is
not in git. That is how you find the thing somebody applied by hand.

## Chart versions are pinned exactly

```yaml
targetRevision: 3.6.0     # not ">=3.6.0", not "3.x"
```

Argo CD accepts a semver range here, and then a cluster component upgrades
itself on some future refresh with no commit anywhere. That is the opposite of
what GitOps is for. `scripts/check_yaml.py` rejects a non-exact chart version.

## Who bootstraps the bootstrapper

Argo CD itself is installed by `scripts/deploy.sh` with `kubectl`, not by Argo
CD. That is the honest answer to "why is this one thing not in git like
everything else": something has to exist before the thing that reconciles git
can run. It can be made to manage its own upgrades afterwards; the first
install cannot come from itself.

`deploy.sh` uses `--server-side` for that apply, because the Argo CD CRDs carry
schemas large enough that a client-side apply can exceed the 262144 byte
annotation limit and fail with `metadata.annotations: Too long`.

## Watching it

```sh
kubectl -n argocd get applications -w

make argocd        # port-forward the UI and print the generated password
```

Everything should reach `Synced / Healthy` in five to ten minutes.

## Deploying a change

```sh
# edit something in app/
git commit -am "feat: change the heading" && git push
```

Then: `build-image.yml` runs, pushes `sha-<new>`, commits the tag, Argo CD picks
it up within about three minutes, the Deployment rolls one pod at a time
(`maxUnavailable: 0`), and the PodDisruptionBudget keeps two replicas serving
throughout.

To roll back:

```sh
git revert <the deploy commit>
git push
```

The old image tag is still in ECR, the lifecycle policy keeps the last twenty,
and it is immutable so it is byte-identical to what was there before.

Next: [05-monitoring.md](05-monitoring.md).
