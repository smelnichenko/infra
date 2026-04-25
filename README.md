# Infra

Argo CD cluster state repository for pmon.dev. GitOps single source of truth for what is deployed.

## Architecture

Argo CD in the `argocd` namespace continuously reconciles this repository against the live cluster state. Woodpecker CD pipelines commit updated image tags here after successful builds. Argo CD detects the changes and triggers Helm upgrades.

```
Code push --> Woodpecker CI/CD --> Kaniko image build --> commit tag here --> Argo CD syncs
```

## Structure

```
infra/
  clusters/
    production/
      argocd/apps/       # Argo CD Applications (one per workload)
      monitor/           # values for the schnappy app chart
      forgejo/           # Forgejo git forge
      woodpecker/        # Woodpecker CI
      vault/             # HashiCorp Vault
      velero/            # Velero backups
      cert-manager/      # TLS certificate management
      external-secrets/  # External Secrets Operator
```

Each Application points at a Helm chart + a values file in this repo.

## How Deploys Work

1. Developer pushes code to a service repo (e.g., `schnappy/monitor`)
2. Woodpecker CD builds and tests the code
3. Kaniko builds a container image, pushes to Forgejo registry
4. Woodpecker's `update-infra` step commits the new image tag to this repo
5. Argo CD detects the commit (poll/webhook) and syncs the Application
6. Helm renders the chart with the new image tag, Kubernetes performs a rolling update

## Operations

```bash
# Check Argo CD application status
ssh ten 'sudo kubectl get applications -n argocd'

# Force immediate sync of an Application
ssh ten 'sudo kubectl -n argocd patch application schnappy --type merge -p "{\"operation\":{\"sync\":{}}}"'

# Check a specific Application
ssh ten 'sudo kubectl describe application schnappy -n argocd'
```

## Important

Do not edit image tags manually. They are managed by Woodpecker CD pipelines. Configuration values (resource limits, feature flags, etc.) can be edited directly and Argo CD will apply them.
