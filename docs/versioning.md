# Immutable service versions with Argo CD (no operator)

Restate pins every in-flight invocation to the deployment it started on. A
service update must therefore start the new version **next to** the old one,
and keep the old one running until nothing is pinned to it any more.

The Restate Kubernetes operator does this with its `RestateDeployment`
resource. Without the operator, the Greeter chart can do it on each Argo CD
sync, with no long-running controller.

## How it works

Turn it on in the service's environment file:

```yaml
image:
  tag: v3            # each new tag is a new version
versioning:
  enabled: true
```

- **One Deployment + Service per version,** named `<release>-<version>` (e.g. `greeter-v3`, from `image.tag`; dots become dashes). They carry two Argo CD annotations:
  - `Prune=false`: a new version doesn't delete the old one;
  - `IgnoreExtraneous`: old versions don't mark the Application OutOfSync.
- **A PostSync "release" Job runs after every sync:**
  1. **Release:** register the new version with Restate. New invocations go to it.
  2. **Reap:** for every other registered version of this service, check:
     - is it still the current deployment for any service?
     - how many unfinished invocations are pinned to it (`sys_invocation`, `status != 'completed'`)?

     If neither, delete it from Restate (`DELETE /deployments/<id>?force=true`, safe because nothing is pinned) and delete its Deployment and Service.
- **Versions still draining are kept.** The next sync (a new release, or a re-sync of the same one) tries again.

Code: `greeter/chart/templates/release-job.yaml`, `greeter/chart/templates/_helpers.tpl`.

## What the platform team provides

The release Job deletes Deployments and Services, so it runs as a dedicated ServiceAccount with a namespaced Role. App teams usually can't create Roles, so the platform does (see `platform/namespace-team-v.yaml`):

```yaml
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "delete"]
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "list", "delete"]
```

The Job image needs `sh`, `curl`, `jq` and `kubectl` (`alpine/k8s` by default; mirror it if public registries are blocked).

## Tested (EKS 1.34, Istio, restricted Pod Security, Argo CD 3.5.6, Restate 1.8.1)

| Step | Result |
|---|---|
| Sync v2 | `greeter-v2` created; release Job: `registered (201)` |
| Start `slowGreet` (durable 300s sleep) | Pinned to `greeter-v2` |
| Bump tag to v3, sync | `greeter-v3` registered and current; `keep greeter-v2: 1 unfinished invocation(s) pinned`; new `greet` calls ran on v3 |
| `slowGreet` finishes | Resumed and completed **on v2** |
| Re-sync (no change) | `reap greeter-v2: drained`: deleted from Restate; Deployment and Service deleted; v3 untouched |
| Throughout | Application `Synced / Healthy` |

`greeter/app` has the `slowGreet` handler (`{"name": "...", "seconds": N}`) for trying this.

## Limits

- **Cleanup happens only on sync.** A drained version keeps running until the next sync or re-sync. For timely cleanup without new releases, run the same script as a CronJob.
- **"Drained" means no unfinished invocations,** including suspended and paused ones. Those keep their version alive, which is the safe direction.
- **Forced deletion is what Restate's API offers.** The check-then-delete is only as safe as the check; there's no lock between them. New invocations never pin to a non-current version, so the window is limited to the pinned invocations already counted.
