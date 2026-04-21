# Infra (Argo CD GitOps)

Argo CD Application manifests and production values files. This repo is the single source of truth for cluster state — Argo CD watches it and reconciles.

## Structure

```
clusters/production/
├── argocd/apps/              # Argo CD Application manifests (app-of-apps)
│   ├── root.yaml             # Root Application (manages all others)
│   ├── schnappy-production-apps.yaml  # Core app chart (prod env)
│   ├── schnappy-production-data.yaml  # Data stores (prod)
│   ├── schnappy-production-mesh.yaml  # Istio mesh (prod)
│   ├── schnappy-test-apps.yaml        # Core app chart (test env)
│   ├── schnappy-test-data.yaml        # Data stores (test)
│   ├── schnappy-test-mesh.yaml        # Istio mesh (test)
│   └── ...                   # cert-manager, vault, velero, istio-*, strimzi, etc.
├── cluster-config/           # Raw manifests (ClusterIssuers, default-deny NPs, PriorityClasses, ESOs)
├── schnappy-production-apps/values.yaml
├── schnappy-production-data/values.yaml
├── schnappy-production-mesh/values.yaml
├── schnappy-test-apps/values.yaml
├── schnappy-observability/values.yaml
├── schnappy-sonarqube/values.yaml
└── istio/                    # Istio Helm values (istiod, cni)
```

## Deploy Flow

Push code → Woodpecker builds image → Woodpecker commits new tag to `schnappy/values.yaml` → Argo CD detects change → syncs Application → rolling update.

## Application Sources

Each Application uses multi-source: Helm chart from `schnappy/platform` repo + values from this repo.

## Full Infrastructure Docs

See `schnappy/ops` repo `CLAUDE.md` for complete infrastructure documentation.
