# Troubleshooting and lessons learned

## What was tested

On EKS 1.34, with Istio 1.30.8 (CNI plugin, PERMISSIVE mTLS), restricted Pod Security on the app namespace, Argo CD v3.5.6, and an app team with namespace-only rights:

- **Restate node-to-node traffic (5122, gRPC) works through Istio sidecars with no extra configuration.** Pods find each other via the headless Service before they're Ready.
- **Restate → service on 9080 (HTTP/2) works through sidecars as-is.** Discovery, invocations and retries were all checked.
- **An in-mesh pod → Restate admin (9070) works:** that's the registration Job.
- **S3 snapshots work via IRSA,** with the AWS calls (STS, S3) going through the sidecar under Istio's default outbound policy.
- **Jobs complete under Istio** because of native sidecars.

## Gotchas found

| Gotcha | Detail |
|---|---|
| `restatectl provision` exit code | Exits **0 even on failure** (e.g. `[ERR]: … dns error`). Check its output; `restatectl partitions list` does exit non-zero when unreachable. |
| Provisioning hook phase | Must be a **Sync** hook, not PostSync. Restate pods aren't Ready until the cluster is provisioned, so PostSync would deadlock. |
| Self-provisioning | Letting `restate-0` auto-provision works, but it stays `auto-provision=true` forever. A one-time Job is safer. |
| Restricted Pod Security | Needs `seccompProfile: RuntimeDefault` (the stock chart doesn't set it), non-root, all capabilities dropped. Istio needs its **CNI plugin** (the default `istio-init` needs NET_ADMIN/NET_RAW). |
| Namespace-only users | Can't create, or even **list**, StorageClasses. Get the class name from the platform team. |
| Argo Applications | Live in `argocd`; app teams usually can't create them directly (see platform-setup step 8). |
| Kubernetes RBAC vs Argo | Argo applies with its own identity, so the AppProject, not the user's RBAC, limits what an Application can create. |
| Istio CNI on brand-new nodes | A pod scheduled on a node that joined seconds ago can fail `istio-validation` (`Init:Error`) because `istio-cni-node` isn't running there yet. Seen when scaling nodes up: the provision Job's first pod failed and the Job's retry (`backoffLimit`) succeeded. Long-running pods recover on their own (the CNI chart's default `repair.repairPods: true` fixes their networking as they restart); Job pods with `restartPolicy: Never` rely on the Job's retries. |
| `kubectl logs -l …` | Shows only 10 lines per pod unless you pass `--tail=-1`. |
| Restate UI playground | Calls the pod IP advertised by the admin API; doesn't work through `port-forward`. Use curl. |

## Symptoms

| Symptom | Likely cause | Fix |
|---|---|---|
| Sync fails: resource kind not permitted | AppProject allow/deny list | Platform allows StatefulSet / PDB / Job / Deployment for the project |
| Pods `Pending`: Insufficient cpu/memory | Nodes too small | Smaller `resources` (keep 1:2), or more/larger nodes; or `whenUnsatisfiable: ScheduleAnyway` |
| Pods `Pending`: PVC not bound | Wrong StorageClass / no EBS CSI | Use the platform's class |
| Pods `Pending` after nodes were replaced | EBS volumes are zonal; no node in that zone | Add a node in the missing zone (a node group per zone avoids this) |
| A Restate pod `Pending`: `didn't match pod topology spread constraints` | Fewer than 3 zones with free capacity | Add capacity in the missing zone; for single-zone test clusters use `topologyKey: kubernetes.io/hostname` |
| Pods rejected: `violates PodSecurity` / UID not allowed | Policy on user IDs or seccomp | Set allowed UIDs; keep `seccompProfile: RuntimeDefault` |
| `ImagePullBackOff` | Public registries blocked | Mirror the images (Restate, curl, your service) |
| Provision Job logs `[ERR] … dns error` / `upstream connect error` | restate-0 not up yet | Normal for ~20 seconds; check pods if it persists |
| Pod `Init:Error`, `istio-validation` log says istio-cni isn't running on the node | New node; CNI agent not ready yet | Usually self-heals (repairPods, Job retries); otherwise delete the pod |
| Job pod stuck `1/2` after finishing | Istio without native sidecars | `sidecar.istio.io/inject: "false"` on the Job's pod template |
| Pods Running but never Ready | Cluster not provisioned | Check `restate-provision` logs |
| Snapshots fail (`AccessDenied`, STS timeouts) | Wrong ServiceAccount, IAM trust, or Istio egress `REGISTRY_ONLY` | Check the SA annotation/association; add ServiceEntries for STS/S3 |
| Registration fails / `bad gateway` | Service not on 9080, Service/port mismatch, mTLS mode mismatch | Check the Job log; curl `http://<svc>:9080` from a pod in the namespace |
