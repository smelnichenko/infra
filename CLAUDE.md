# Infra (Argo CD GitOps)

Argo CD Application manifests and production values files. This repo is the single source of truth for cluster state — Argo CD watches it and reconciles.

## Structure

```
clusters/production/
├── argocd/apps/              # Argo CD Application manifests (app-of-apps)
│   ├── root.yaml             # Root Application (manages all others)
│   ├── schnappy.yaml         # Core app chart
│   ├── schnappy-data.yaml    # Data stores chart
│   ├── schnappy-auth.yaml    # Keycloak chart
│   ├── schnappy-mesh.yaml    # Istio mesh config chart
│   └── ...                   # cert-manager, vault, velero, forgejo, woodpecker, istio, metallb, etc.
├── cluster-config/           # Raw manifests (ClusterIssuers, default-deny NPs, velero MinIO)
├── schnappy/values.yaml      # Core app production values (image tags updated by CD pipeline)
├── schnappy-data/values.yaml
├── schnappy-auth/values.yaml
├── schnappy-observability/values.yaml
├── schnappy-sonarqube/values.yaml
├── schnappy-mesh/values.yaml
└── istio/                    # Istio Helm values (istiod, cni, ztunnel)
```

## Deploy Flow

Push code → Woodpecker builds image → Woodpecker commits new tag to `schnappy/values.yaml` → Argo CD detects change → syncs Application → rolling update.

## Application Sources

Each Application uses multi-source: Helm chart from `schnappy/platform` repo + values from this repo.

## Full Infrastructure Docs

See `schnappy/ops` repo `CLAUDE.md` for complete infrastructure documentation.
