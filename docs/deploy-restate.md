# Deploy the Restate cluster with Argo CD

For the **app team**. It needs only namespace rights and an Argo CD Application
that the platform team created ([platform-setup.md](platform-setup.md)). No
operator, no CRDs, and no `kubectl exec` or `port-forward`.

## What gets deployed

`restate/chart` is Restate's `restate-helm` 1.8.1 chart with three small additions:

| Addition | Why |
|---|---|
| `serviceAccount.name` | Run as an existing, IAM-linked ServiceAccount instead of creating one |
| `extraEnv` | Per-environment env vars, appended after `env` |
| `templates/provision-job.yaml` | Provisions the cluster exactly once, as an Argo CD **Sync hook** |

The chart creates only namespaced objects: StatefulSet `restate` (3 pods), Service `restate` (8080 ingress, 9070 admin, 5122), headless Service `restate-cluster`, a PodDisruptionBudget, 3 PVCs (via the StatefulSet), and the provision Job.

## 1. Set your values

The values come in two files, applied in this order:

| File | Contains | Edit? |
|---|---|---|
| `restate/values-cluster.yaml` | How Restate runs: 3 replicas, Restate version, provision Job (36 partitions, replication 2), `RESTATE_AUTO_PROVISION=false`, metadata address, RocksDB and snapshot tuning, 4 vCPU / 8 GiB, one pod per node, PDB, seccomp `RuntimeDefault` | No |
| `restate/values-env.yaml` | Your environment: ServiceAccount, StorageClass and size, image registry, `AWS_REGION` and the snapshot destination (via `extraEnv`), and commented-out user-ID overrides | **Yes** |

In `values-env.yaml`:

| Value | Example | Notes |
|---|---|---|
| `serviceAccount.name` | `restate-workload` | The ServiceAccount the platform linked to IAM |
| `storage.storageClassName` / `storage.size` | `gp3` / `20Gi` | Ask the platform team for the class; size for your load (e.g. 100Gi+ for a 24h load test) |
| `image.repository` | `docker.restate.dev/restatedev/restate` | Your mirror, if public registries are blocked |
| `AWS_REGION` | `us-east-2` | Region of the bucket |
| `RESTATE_WORKER__SNAPSHOTS__DESTINATION` | `s3://<bucket>/restate/snapshots` | A bucket/prefix only this Restate cluster uses |
| `securityContext` / `podSecurityContext` (commented) | chart defaults UID 1000 / GID 3000 / fsGroup 2000 | Only if your policy requires other IDs; keep seccomp `RuntimeDefault` |

`extraEnv` is appended after the `env` list in `values-cluster.yaml`. Helm replaces lists rather than merging them, so per-environment env vars go here.

Commit and push.

## 2. Sync

In the Argo CD UI: open the **`team-a-restate`** Application, then **Refresh** (it picks up your commit), then **Sync**, then **Synchronize**.

From the CLI, `argocd app sync team-a-restate` does the same thing.

## 3. What happens (about 1–2 minutes)

1. Argo applies the StatefulSet, Services and PDB. 3 pods start, one per node, each `2/2` with the Istio sidecar. They are **not Ready** yet, because nothing has provisioned the cluster.
2. In the same sync wave, the **`restate-provision`** Job runs:
   ```
   [ERR]: Failed to provision cluster during dry run: dns error       ← restate-0 not up yet
   Attempt 1: not provisioned yet; retrying in 5s
   ...
   ✅ Cluster has been successfully provisioned.
   ...
   🤷 Cluster has been provisioned by somebody else.
   Cluster is provisioned.
   ```
3. The pods turn Ready, and the Application shows **Synced / Healthy**.

On later syncs, the Job prints "provisioned by somebody else" and exits right away.

Why a **Sync** hook and not PostSync: Argo only runs PostSync hooks once everything is Healthy, and Restate pods aren't Ready until the cluster is provisioned, so PostSync would deadlock. Why the Job checks output text: `restatectl provision` exits 0 even when it fails. The Job only succeeds when the output says "provisioned" with no `[ERR]`, **and** `restatectl partitions list` succeeds.

## 4. Verify

With just the Argo UI: the resource tree is green, and the `restate-provision` log ends with `Cluster is provisioned.`

With `kubectl exec`:

```bash
kubectl -n team-a exec restate-0 -c restate -- restatectl status
# 3 nodes "Member"; LEADER column sums to 36
kubectl -n team-a exec restate-0 -c restate -- restatectl snapshots create-snapshot
aws s3 ls s3://<bucket>/restate/snapshots/ --recursive | head
```

Without exec, snapshots appear by themselves once a partition passes 100k records.

UI, with `port-forward`:

```bash
kubectl -n team-a port-forward svc/restate 9070:9070 8080:8080
# http://localhost:9070/ui
```

The UI's playground sends requests to the pod IP it's told about, which your browser can't reach. Use `curl localhost:8080/...`, or set `RESTATE_INGRESS__ADVERTISED_ADDRESS`.

## Availability zones

`values-cluster.yaml` spreads the 3 Restate pods **one per availability zone** (`topologyKey: topology.kubernetes.io/zone`, `DoNotSchedule`). With one Restate node per zone, `replication 2` always places a partition's two copies, and each log record's two copies, in **different zones**. Losing a zone leaves 2 of 3 nodes: the metadata store keeps its majority, every partition keeps a copy, and the log can still write to 2 nodes.

- **Fewer than 3 zones with capacity:** pods stay `Pending` rather than doubling up in a zone. That's deliberate. For a test cluster in one zone, use `topologyKey: kubernetes.io/hostname` instead.
- **More than 3 Restate nodes** (e.g. 6, two per zone): node-level replication could then put both copies in one zone. Restate supports zone-aware placement:
  - give each node its location with `RESTATE_LOCATION=<region>.<zone>` (e.g. `us-east-2.us-east-2a`);
  - provision with zone-scoped replication, e.g. `--replication '{zone: 2}'`.

  Set the location **before** the first provisioning; Restate warns that changing a node's location later can lose data. Pods don't see their zone by default, so this needs an init container that reads its node's `topology.kubernetes.io/zone` label (the platform grants read-only access to nodes). It isn't part of this repo.

## 5. Change or upgrade

Edit values (for example `image.tag`), commit, then Refresh and Sync. Pods roll one at a time (PDB `maxUnavailable: 1`), and the provision Job is a no-op.

## Without Argo CD (plain Helm)

See [deploy-without-argo.md](deploy-without-argo.md). In short: `helm install restate ./restate/chart -n <namespace> -f restate/values-cluster.yaml -f restate/values-env.yaml` (no `--wait`). The provision Job runs as a Helm post-install/post-upgrade hook.
