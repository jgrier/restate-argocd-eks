# Platform setup

What the **platform team** (cluster admins) sets up once, so that an **app team
with namespace-only rights** can deploy Restate and Restate services through
Argo CD. Everything here is cluster-scoped, touches IAM, or lives in the
`argocd` namespace, so app teams can't do it themselves.

Run from the repo root.

```bash
cp platform/env.example.sh platform/env.sh   # edit it; it's git-ignored
source platform/env.sh
```

| Step | Creates | Why the app team can't |
|---|---|---|
| 1 | EKS cluster (or use an existing one) | Cluster-level |
| 2 | StorageClass `gp3` | Cluster-scoped |
| 3 | Istio (base + CNI + istiod) | CRDs, DaemonSet, webhooks |
| 4 | Argo CD | CRDs, cluster roles |
| 5 | Namespace `team-a` (Istio + restricted PSS labels) + RoleBinding | Namespaces and their labels |
| 6 | Snapshot bucket, IAM policy, IRSA ServiceAccount `restate-workload` | IAM |
| 7 | (Optional) An AWS identity for an app-team user `joe` | IAM, EKS access entries |
| 8 | Argo CD repo access, AppProject `team-a`, Applications | `argocd` namespace; the AppProject is the guardrail |

## 1. Cluster

```bash
eksctl create cluster -f platform/cluster.eksctl.yaml     # ~20 min
kubectl get nodes -L topology.kubernetes.io/zone          # one node per zone
```

The example uses **three availability zones with one node group per zone**:
- Restate places one pod per zone, so the cluster survives losing a zone (see [deploy-restate.md](deploy-restate.md#availability-zones)).
- Each pod's EBS volume lives in one zone, so that pod can only run in that zone. A per-zone node group guarantees each zone keeps capacity; a single group spread over zones can scale or rebalance a zone away and leave the pod `Pending`.

Using an existing cluster instead, it needs:
- the EBS CSI driver;
- an IAM OIDC provider (for IRSA);
- nodes in **3 availability zones**, each zone able to fit one Restate pod (**4 vCPU / 8 GiB free**, plus ~0.1 CPU / 128 Mi for its Istio sidecar), ideally from a node group per zone.

Restate needs **block storage (EBS)**, not EFS/NFS.

## 2. StorageClass

```bash
kubectl apply -f platform/storageclass-gp3.yaml
```

`Retain` keeps EBS volumes after their PVCs are deleted. Clean them up explicitly (see "Teardown").

## 3. Istio with the CNI plugin

The CNI plugin sets up each pod's traffic redirect from the node. Pods then don't need the privileged `istio-init` container, which is what lets them pass the **restricted** Pod Security Standard.

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts && helm repo update istio
helm install istio-base istio/base -n istio-system --create-namespace --version 1.30.8 --wait
helm install istio-cni  istio/cni  -n istio-system --version 1.30.8 --wait
helm install istiod     istio/istiod -n istio-system --version 1.30.8 --set pilot.cni.enabled=true --wait
kubectl -n istio-system get pods      # istio-cni-node on every node, istiod Running
```

Istio is optional; everything here also works without it. On Kubernetes 1.29+, Istio injects **native sidecars**, so Jobs (provisioning, registration) complete normally. On older setups, add `sidecar.istio.io/inject: "false"` to the Job pod templates.

## 4. Argo CD

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update argo
helm install argocd argo/argo-cd -n argocd --create-namespace --version 10.11.6 --wait
kubectl -n argocd get pods
# UI: kubectl -n argocd port-forward svc/argocd-server 8443:443  →  https://localhost:8443
# admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## 5. Namespace and app-team rights

```bash
kubectl apply -f platform/namespace-team-a.yaml
```

This creates namespace `team-a` with labels `istio-injection=enabled` and Pod Security `restricted`, plus RoleBinding `joe-admin`, which gives Kubernetes user `joe` the built-in `admin` role **in `team-a` only**.

## 6. Snapshot bucket and the workload's AWS identity

Restate writes partition snapshots to S3. Its pods run as an **existing ServiceAccount that the platform links to an IAM role**. The app team can't create IAM roles; they just reference the ServiceAccount by name in their values.

```bash
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

envsubst < platform/iam/snapshot-bucket-policy.json.tmpl > /tmp/snapshot-policy.json
aws iam create-policy --policy-name "$CLUSTER-$NAMESPACE-restate-snapshots" \
  --policy-document file:///tmp/snapshot-policy.json

eksctl create iamserviceaccount --region "$REGION" --cluster "$CLUSTER" \
  --namespace "$NAMESPACE" --name "$WORKLOAD_SA" --role-name "$CLUSTER-$NAMESPACE-workload" \
  --attach-policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$CLUSTER-$NAMESPACE-restate-snapshots" --approve
kubectl -n "$NAMESPACE" get sa "$WORKLOAD_SA" -o yaml   # annotation eks.amazonaws.com/role-arn
```

With IRSA, EKS injects `AWS_ROLE_ARN` and a web-identity token into pods that use this ServiceAccount, and the AWS SDK in Restate picks them up. EKS Pod Identity works the same way from Restate's point of view.

## 7. (Optional) An AWS identity for app-team user `joe`

Maps an IAM role to Kubernetes user `joe` with **no EKS access policy**, so joe's only rights are the RoleBinding from step 5.

```bash
envsubst < platform/iam/joe-trust-policy.json.tmpl > /tmp/joe-trust.json
envsubst < platform/iam/joe-permissions.json.tmpl  > /tmp/joe-perms.json
aws iam create-role --role-name "$CLUSTER-joe" --assume-role-policy-document file:///tmp/joe-trust.json
aws iam put-role-policy --role-name "$CLUSTER-joe" --policy-name joe-minimal --policy-document file:///tmp/joe-perms.json
aws eks create-access-entry --region "$REGION" --cluster-name "$CLUSTER" \
  --principal-arn "arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER-joe" --username joe --type STANDARD
```

## 8. Argo CD: repo access, project, Applications

Read-only deploy key for the repo (if private):

```bash
mkdir -p platform/secrets
ssh-keygen -t ed25519 -N "" -C argocd -f platform/secrets/argocd-deploy-key
gh repo deploy-key add platform/secrets/argocd-deploy-key.pub --repo <owner>/<repo> --title argocd
REPO_SECRET="repo-$(basename "$REPO" .git)"        # one secret per repo
kubectl -n argocd create secret generic "$REPO_SECRET" \
  --from-literal=type=git --from-literal=url="$REPO" \
  --from-file=sshPrivateKey=platform/secrets/argocd-deploy-key
kubectl -n argocd label secret "$REPO_SECRET" argocd.argoproj.io/secret-type=repository
```

Project and Applications:

```bash
kubectl apply -f argocd/appproject-team-a.yaml
kubectl apply -f argocd/app-restate.yaml -f argocd/app-greeter.yaml
```

- **The AppProject is the guardrail.** Argo CD applies changes with its own (powerful) identity, so the project limits what any Application in it can do: one source repo, one destination namespace, **no cluster-scoped kinds**, no Role/RoleBinding/ResourceQuota/LimitRange. Only the platform team edits it.
- **Applications live in `argocd`,** so creating them is a platform/onboarding step here. Alternatives:
  - Argo CD RBAC can let a team create Applications in its project from the UI or CLI;
  - an ApplicationSet can generate them from a config repo;
  - "apps in any namespace" (off by default) lets teams create them in their own namespace.
- The Applications are `team-a-restate` and `team-a-greeter` (Helm releases `restate` and `greeter`). Both use **manual sync**; the app team syncs them. See [deploy-restate.md](deploy-restate.md) and [deploy-app.md](deploy-app.md).

## Teardown

```bash
kubectl -n argocd delete application team-a-greeter team-a-restate
kubectl delete namespace team-a                  # deletes PVCs; PVs are Retained
kubectl get pv                                   # delete Released PVs, then their EBS volumes
eksctl delete iamserviceaccount --region "$REGION" --cluster "$CLUSTER" --namespace "$NAMESPACE" --name "$WORKLOAD_SA"
aws iam delete-policy --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$CLUSTER-$NAMESPACE-restate-snapshots"
aws s3 rb "s3://$BUCKET" --force
```
