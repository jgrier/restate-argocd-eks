# Deploy a Restate service with Argo CD

For the **app team**. The service runs as its **own** Argo CD Application,
separate from the Restate cluster, and registers itself with Restate after
each sync. No `port-forward` needed.

The example is `greeter/`: Restate's Spring Boot template (`Greeter.greet`, with simulated failures that Restate retries).

| Path | What it is |
|---|---|
| `greeter/app/` | Java source and `Dockerfile` |
| `greeter/chart/` | Deployment + Service on port **9080**, and a **PostSync** Job that registers the service |
| `greeter/values-env.yaml` | Your environment: the image (and the Restate admin URL) |

## 1. Build and push the image

```bash
cd greeter/app
docker buildx build --platform linux/amd64 -t <registry>/restate-greeter:v1 --push .
```

Then set `image.repository` / `image.tag` in `greeter/values-env.yaml`, commit and push.

## 2. Sync

In the Argo CD UI: open the **`team-a-greeter`** Application, then **Refresh**, **Sync**, **Synchronize**.

## 3. What happens

1. The Deployment starts 2 pods (`2/2` with the Istio sidecar). They're non-root, drop all capabilities and use seccomp `RuntimeDefault`, so they pass restricted Pod Security.
2. Once they're Healthy, the **`greeter-register`** PostSync Job POSTs this to `http://restate:9070/deployments`:
   ```json
   {"uri": "http://greeter.team-a.svc.cluster.local:9080"}
   ```
   Restate then calls the service on 9080 to discover its handlers. The Job log ends with `OK (201)`, or `OK (409)` if it was already registered.
3. The Application shows **Synced / Healthy**.

To use the registration Job with your own service, copy `greeter/chart/templates/register-job.yaml` into its chart and keep the service on port 9080. If Docker Hub is blocked, set `registration.image` to your mirror of `curlimages/curl`.

## 4. Invoke

```bash
kubectl -n team-a port-forward svc/restate 8080:8080
curl localhost:8080/Greeter/greet --json '{"name":"Bob"}'     # → {"message":"You said hi to Bob!"}
curl localhost:8080/Greeter/greet --json '{"name":"Alice"}'   # fails ~70% per step; Restate retries
```

Or call `http://restate:8080/Greeter/greet` from any pod in the namespace.

The service's logs show the simulated failures (`[👻 SIMULATED] Failed to send notification…`), Restate retrying with backoff, and each step completing exactly once.

In the Restate UI (`port-forward svc/restate 9070:9070`, then http://localhost:9070/ui), open an invocation to see its journal.

## New versions

Restate pins in-flight invocations to the deployment they started on. For a new version:
- deploy it as a **new deployment** (new Service/URL) and register it;
- keep the old one running until its invocations finish.

The Restate Kubernetes operator automates this; with plain Argo CD it's manual.
