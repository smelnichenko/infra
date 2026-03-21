# Infra

Flux CD cluster state repository for pmon.dev. GitOps single source of truth for what is deployed.

## Architecture

Flux CD controllers in the `flux-system` namespace continuously reconcile this repository against the live cluster state. Woodpecker CD pipelines commit updated image tags here after successful builds. Flux detects the changes (polling every 1 minute) and triggers Helm upgrades.

```
Code push --> Woodpecker CI/CD --> Kaniko image build --> commit tag here --> Flux reconciles
```

## Structure

```
infra/
  clusters/
    production/
      monitor/           # HelmRelease + values for the main application
      forgejo/           # Forgejo git forge
      woodpecker/        # Woodpecker CI
      vault/             # HashiCorp Vault
      velero/            # Velero backups
      cert-manager/      # TLS certificate management
      external-secrets/  # External Secrets Operator
```

Each subdirectory contains:

- **Kustomization** -- tells Flux what to apply
- **HelmRelease** -- Helm chart reference with values (including image tags)

## How Deploys Work

1. Developer pushes code to a service repo (e.g., `schnappy/monitor`)
2. Woodpecker CD builds and tests the code
3. Kaniko builds a container image, pushes to Forgejo registry
4. Woodpecker's `update-infra` step commits the new image tag to this repo
5. Flux source-controller detects the commit (1-minute poll)
6. Flux helm-controller upgrades the HelmRelease with the new image tag
7. Kubernetes performs a rolling update

## Operations

```bash
# Check Flux reconciliation status
ssh ten 'sudo k3s kubectl get kustomizations,helmreleases -A'

# Force immediate reconciliation
ssh ten 'sudo k3s kubectl annotate gitrepository/infra -n flux-system reconcile.fluxcd.io/requestedAt=$(date +%s) --overwrite'

# Check a specific HelmRelease
ssh ten 'sudo k3s kubectl describe helmrelease monitor -n monitor'
```

## Important

Do not edit image tags manually. They are managed by Woodpecker CD pipelines. Configuration values (resource limits, feature flags, etc.) can be edited directly and Flux will apply them.
