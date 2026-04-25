# Pending — needs prerequisite credentials

Manifests here are valid but not yet picked up by Argo CD's `root` app
(which only watches `apps/`). Enable each by `git mv` to `../apps/`
once its prerequisite is in place.

## schnappy-pr-envs.yaml — Plan 067 ApplicationSet

Needs `secret/argocd/forgejo-readonly { token: <Forgejo PAT> }` in Pi
Vault. The accompanying `forgejo-readonly-token.yaml`,
`preview-shared-secrets.yaml`, `stale-pr-envs-cronjob.yaml`,
`projects.yaml`, and `cert-manager/preview-wildcard.yaml` should land
together (also need to be wired into root or a parent Application).
