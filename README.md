# Restate on EKS with Argo CD

Deploy a replicated [Restate](https://restate.dev) cluster and a Restate
service into a single Kubernetes namespace with Argo CD, as an **app team with
namespace-only rights**:

- no operator, no CRDs, nothing cluster-scoped in the app team's deploys;
- works under **Istio** (with the CNI plugin) and the **restricted** Pod Security Standard;
- no `kubectl exec` or `port-forward` needed: a Sync-hook Job provisions the cluster, and a PostSync Job registers the service;
- partition snapshots to **S3 via IRSA**, using a ServiceAccount the platform team set up.

Tested on EKS 1.34, Istio 1.30.8, Argo CD v3.5.6, Restate 1.8.1.

## Layout

| Path | What it is |
|---|---|
| `restate/` | Argo CD app 1, the Restate cluster: `chart/` (`restate-helm` 1.8.1 + small additions) and `values-team-a.yaml` |
| `greeter/` | Argo CD app 2, a sample service: `app/` (Spring Boot source + Dockerfile), `chart/`, `values-team-a.yaml` |
| `argocd/` | AppProject `team-a` and the two Applications |
| `platform/` | Example EKS cluster, StorageClass, namespace + RBAC, IAM policy templates, `env.example.sh` |
| `docs/` | How to set it up and deploy, plus troubleshooting |

## Docs

1. [Platform setup](docs/platform-setup.md): what cluster admins set up once (cluster, storage, Istio, Argo CD, namespace, IAM, project).
2. [Deploy Restate](docs/deploy-restate.md): the app team deploys the Restate cluster with Argo CD.
3. [Deploy a Restate service](docs/deploy-app.md): the app team deploys and registers a service with Argo CD.
4. [Troubleshooting and lessons learned](docs/troubleshooting.md)

## Using it in your environment

Change the lines marked `# per environment` in `restate/values-team-a.yaml` and `greeter/values-team-a.yaml` (ServiceAccount, bucket, region, StorageClass, images). Then change the repo URL and namespace in `argocd/`, and the variables in `platform/env.sh`.

Nothing in the repo is account-specific. IAM role ARNs live only on the platform-created ServiceAccount.
