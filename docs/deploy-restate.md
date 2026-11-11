# Deploy the Restate cluster with Argo CD

For the **app team**. It needs only namespace rights and an Argo CD Application
that the platform team created ([platform-setup.md](platform-setup.md)). No
operator, no CRDs, and no `kubectl exec` or `port-forward`.

## What gets deployed

`restate/chart` is Restate's `restate-helm` 1.8.1 chart with two small additions:

| Addition | Why |
|---|---|
| `serviceAccount.name` | Run as an existing, IAM-linked ServiceAccount instead of creating one |
| `templates/provision-job.yaml` | Provisions the cluster exactly once, as an Argo CD **Sync hook** |

The chart creates only namespaced objects: StatefulSet `restate` (3 pods), Service `restate` (8080 ingress, 9070 admin, 5122), headless Service `restate-cluster`, a PodDisruptionBudget, 3 PVCs (via the StatefulSet), and the provision Job.

## 1. Set your values

Edit `restate/values-team-a.yaml` (or copy it to `values-<your-env>.yaml` and point the Application at it). The lines marked `# per environment`:

| Value | Example | Notes |
|---|---|---|
| `image.repository` | `docker.restate.dev/restatedev/restate` | Your mirror, if public registries are blocked |
| `serviceAccount.name` | `restate-workload` | The ServiceAccount the platform linked to IAM |
| `AWS_REGION` | `us-east-2` | Region of the bucket |
| `RESTATE_WORKER__SNAPSHOTS__DESTINATION` | `s3://<bucket>/restate/snapshots` | Bucket only this Restate cluster uses |
| `storage.storageClassName` / `storage.size` | `gp3` / `20Gi` | Ask the platform team for the class name; size for your load (e.g. 100Gi+ for a 24h load test) |

Usually left alone:
- **`resources`:** 4 vCPU / 8 GiB. Keep 1:2 CPU:RAM and keep `RESTATE_ROCKSDB_TOTAL_MEMORY_SIZE` under half of memory.
- **`provisionJob`:** 36 partitions, replication 2.
- **`RESTATE_AUTO_PROVISION=false`:** required; the Job provisions the cluster instead.
- **`podSecurityContext` / chart `securityContext`:** non-root UID 1000 / GID 3000 / fsGroup 2000, seccomp `RuntimeDefault`. Override the IDs if your policy requires a range.

Commit and push.

## 2. Sync

In the Argo CD UI: open the **`restate`** Application, then **Refresh** (it picks up your commit), then **Sync**, then **Synchronize**.

From the CLI, `argocd app sync restate` does the same thing.

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

## 5. Change or upgrade

Edit values (for example `image.tag`), commit, then Refresh and Sync. Pods roll one at a time (PDB `maxUnavailable: 1`), and the provision Job is a no-op.

## Without Argo CD (plain Helm)

```bash
helm install restate ./restate/chart -n team-a -f restate/values-team-a.yaml
```

Helm ignores the Argo hook annotation, so the provision Job runs once at install as an ordinary resource.
