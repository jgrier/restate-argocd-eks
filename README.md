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

## Use this repo

1. **Copy it into your own git:** clone it and push to a repo your Argo CD can read.
2. **Edit these files, and only these.** Every line to change is marked `# per environment`:

   | File | What to set |
   |---|---|
   | `restate/values-team-a.yaml` | `serviceAccount.name`, `AWS_REGION`, snapshot bucket, `storage.storageClassName` (and `image.repository` if you use a mirror) |
   | `greeter/values-team-a.yaml` | `image.repository` / `image.tag` (only if not using the public image) |
   | `argocd/appproject-team-a.yaml` | project name, repo URL, namespace |
   | `argocd/app-restate.yaml`, `argocd/app-greeter.yaml` | Application name, project, repo URL, namespace |
   | `platform/namespace-team-a.yaml` | namespace name (if the platform part creates it from this file) |

3. **Platform part** (once per cluster and namespace; skip anything your platform team already provides): follow [docs/platform-setup.md](docs/platform-setup.md) with `platform/env.sh`. Use the same namespace, ServiceAccount, bucket and repo URL you set in step 2.
4. **Commit and push.** Create the Argo CD project and Applications (`kubectl apply -f argocd/`, done by the platform team in most setups).
5. **Sync the Restate Application first, then the Greeter one** (Argo CD UI: Refresh → Sync → Synchronize). Verify with [docs/deploy-restate.md](docs/deploy-restate.md) and [docs/deploy-app.md](docs/deploy-app.md).

Nothing in the repo is account-specific. IAM role ARNs live only on the platform-created ServiceAccount.
