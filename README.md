# Infra

Argo CD cluster state repository for pmon.dev. GitOps single source of truth for what is deployed.

## Architecture

Argo CD in the `argocd` namespace continuously reconciles this repository against the live cluster. Woodpecker CD pipelines commit updated image tags here after successful builds, and Argo CD syncs the affected Applications. Cluster bootstrap (the "root" app) is an `ApplicationSet`-driven app-of-apps.

```
Code push → Woodpecker CI/CD → Kaniko image build → commit tag here → Argo CD syncs
```

## Structure

```
infra/
  clusters/
    production/
      argocd/apps/                   # Argo CD Applications + ApplicationSets
      cluster-config/                # cluster-wide config (StorageClasses, etc.)
      cert-manager/  external-secrets/  cnpg/  istio*/  metrics-server/  porkbun-webhook/  prometheus/  strimzi/  velero/  woodpecker/  forgejo/  vault/  scylla-{operator,manager}/
      schnappy-production-apps/      # values for schnappy chart  (apps namespace)
      schnappy-production-data/      # values for schnappy-data   (data namespace)
      schnappy-production-mesh/      # values for schnappy-mesh   (Istio policies)
      schnappy-test-{apps,data,mesh}/ # Vagrant test envs
      schnappy-infra-{data,mesh}/    # cluster-internal infra (Forgejo DB, Woodpecker, etc.)
      schnappy-observability/        # ELK + Mimir + Grafana + Alertmanager
      schnappy-sonarqube/
```

Each Application points at a Helm chart (in the `schnappy/platform` repo) plus a values file in this repo.

## How Deploys Work

1. Developer pushes code to a service repo (e.g., `schnappy/monitor`)
2. Woodpecker CD builds and tests the code
3. Kaniko builds a container image and pushes to the Forgejo registry
4. Woodpecker's `update-infra` step commits the new image tag to this repo
5. Argo CD detects the commit (poll/webhook) and syncs the Application
6. Helm renders the chart with the new image tag; Kubernetes performs a rolling update

## Operations

```bash
# List all applications
ssh ten 'sudo kubectl get applications -n argocd'

# Inspect one
ssh ten 'sudo kubectl describe application schnappy-production-apps -n argocd'

# Force immediate sync (avoid on the root app — cascades)
ssh ten 'sudo kubectl -n argocd patch application schnappy-production-apps \
  --type merge -p "{\"operation\":{\"sync\":{}}}"'
```

## Important

- **Do not edit image tags manually.** They are managed by Woodpecker CD.
- **Never force-sync or prune the root app** — it cascade-deletes all child Applications.
- **Never prune stateful apps** (`schnappy-*-data`, `vault`, `forgejo`, `cnpg`) — prune deletes StatefulSets/PVCs.
- Configuration values (resource limits, feature flags, etc.) can be edited directly; Argo CD will apply them on the next sync.
