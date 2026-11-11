# Deploy with Helm and namespace-only rights (no Argo CD)

For an app-team user who has **admin in one namespace and nothing
cluster-wide**: no Argo CD, no CRDs, no cluster roles. The same charts and the
same one file to edit as the Argo CD path; Helm runs the provisioning and
registration Jobs as post-install/post-upgrade hooks.

Tested end to end on EKS 1.34 with Istio (CNI) and restricted Pod Security, as a
real IAM role mapped to Kubernetes user `joe` with only a namespace RoleBinding
(no EKS access policy).

## What you need from the platform team

| Item | Why | See |
|---|---|---|
| A namespace where you have the built-in `admin` role (RoleBinding) | Create StatefulSets, Services, Jobs, PDBs, PVCs; `exec`/`port-forward` to check things | [platform-setup.md](platform-setup.md) step 5 |
| An AWS identity mapped into the cluster (EKS access entry or `aws-auth`), plus `eks:DescribeCluster` | Build your kubeconfig | step 7 |
| An existing ServiceAccount linked to an IAM role that can use a snapshot bucket, and the bucket's name | Restate's S3 snapshots; you can't create IAM roles | step 6 |
| The name of an EBS StorageClass | You can't list StorageClasses with namespace rights | step 2 |
| Nodes in 3 zones, each able to fit a 4 vCPU / 8 GiB pod | One Restate pod per zone | step 1 |
| If Istio restricts egress: access to STS and S3 | Snapshots | |

## 1. Get cluster access and check your rights

```bash
aws eks update-kubeconfig --name <cluster> --region <region> --profile <your-profile> \
  --kubeconfig ~/.kube/<cluster> --alias <cluster>
export KUBECONFIG=~/.kube/<cluster>
kubectl auth whoami

for c in "create statefulsets.apps" "create jobs.batch" "create pods/exec" "create pods/portforward"; do
  echo "$c: $(kubectl auth can-i $c -n <namespace>)"     # all yes
done
kubectl auth can-i list nodes                             # no; expected
```

(In zsh, use `${=c}` instead of `$c`.)

## 2. Get the repo and edit one file

```bash
git clone https://github.com/jgrier/restate-argocd-eks.git && cd restate-argocd-eks
```

Edit **`restate/values-env.yaml`**:

| Setting | Set to |
|---|---|
| `serviceAccount.name` | the ServiceAccount the platform linked to IAM |
| `RESTATE_WORKER__SNAPSHOTS__DESTINATION` | `s3://<bucket>/restate/snapshots` |
| `AWS_REGION` | the bucket's region |
| `storage.storageClassName` / `storage.size` | your StorageClass / size |
| `image.repository` | your registry mirror, if public registries are blocked |

In the test, only the bucket line changed (the ServiceAccount was already named `restate-workload`).

## 3. Install Restate

```bash
helm install restate ./restate/chart -n <namespace> \
  -f restate/values-cluster.yaml -f restate/values-env.yaml --timeout 10m
```

- **Don't add `--wait`.** Helm would wait for the Restate pods to be Ready before running the provisioning hook, but the pods only become Ready after it, so the install would time out.
- Helm returns once the `restate-provision` hook Job has finished: **about 30 seconds** in the test.

Check:

```bash
kubectl -n <namespace> get pods,pvc                     # restate-0..2 at 2/2, 3 PVCs Bound
kubectl -n <namespace> logs job/restate-provision -c provision | tail -3
#   ✅ Cluster has been successfully provisioned.
#   🤷 Cluster has been provisioned by somebody else.
#   Cluster is provisioned.
kubectl -n <namespace> exec restate-0 -c restate -- restatectl status       # 3 nodes "Member", 36 partitions
kubectl -n <namespace> exec restate-0 -c restate -- restatectl snapshots create-snapshot
#   "Snapshot created" for each partition; objects appear under s3://<bucket>/restate/snapshots/
```

## 4. Install a service (Greeter) and invoke it

```bash
helm install greeter ./greeter/chart -n <namespace> -f greeter/values-env.yaml --timeout 5m
kubectl -n <namespace> logs job/greeter-register -c register | tail -1     # OK (201)

kubectl -n <namespace> port-forward svc/restate 8080:8080 9070:9070
curl localhost:8080/Greeter/greet --json '{"name":"Joe"}'                 # {"message":"You said hi to Joe!"}
# UI: http://localhost:9070/ui
```

`greeter/values-env.yaml` only needs changing if you use your own image. For your own service, copy `greeter/chart/templates/register-job.yaml` into its chart and keep it on port 9080.

## 5. Upgrade

Change a value (e.g. `image.tag` in a values file), then:

```bash
helm upgrade restate ./restate/chart -n <namespace> -f restate/values-cluster.yaml -f restate/values-env.yaml --timeout 10m
helm upgrade greeter ./greeter/chart -n <namespace> -f greeter/values-env.yaml --timeout 5m
```

- **Restate** rolls one pod at a time (PDB). The provision hook re-runs and is a no-op ("provisioned by somebody else").
- **Greeter**'s registration hook re-registers with `"force": true`, so new or changed handlers are picked up. Tested: an upgrade that added a `slowGreet` handler took Restate's `Greeter` service from revision 1 to 2. This is an in-place update: invocations already running continue on the new code. For long-running workflows, use immutable versions instead.

## 6. Uninstall

```bash
helm uninstall greeter -n <namespace>
helm uninstall restate -n <namespace>
kubectl -n <namespace> delete job restate-provision greeter-register     # Helm leaves hook Jobs
kubectl -n <namespace> delete pvc storage-restate-0 storage-restate-1 storage-restate-2
```

The disks (PVs, `Retain`) stay behind as `Released`. Namespace users can't list or delete PVs, so **ask the platform team** to delete them and their EBS volumes. Restate's data lives on those volumes until then.

## Differences from the Argo CD path

| | Argo CD | Helm, namespace-only |
|---|---|---|
| Who applies | Argo CD's own identity, limited by the AppProject | You, limited by your RoleBinding |
| Provisioning Job | Sync hook, every sync | post-install/post-upgrade hook |
| Registration Job | PostSync hook | post-install/post-upgrade hook |
| Drift | Argo shows and can fix it | None; `helm upgrade` is the source of truth |
| Cleanup | Applications + platform | `helm uninstall`, delete Jobs and PVCs, platform deletes PVs |
