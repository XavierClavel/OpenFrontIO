# Kubernetes manifests

Kustomize tree for running OpenFront on the k3s cluster described in the
[kubeconfig](https://github.com/XavierClavel/kubeconfig) repo. Cluster-scoped and
shared infrastructure (Traefik, the `letsencrypt-prod` ClusterIssuer) stays
there; only what belongs to this application lives here.

```
k8s/
├── base/                 namespace- and host-agnostic application manifests
└── overlays/prod/        namespace: openfront, the public hostname, the image tag
```

## What runs

One Deployment, one pod, one container: the image built from the repository's
`Dockerfile`. Inside it supervisord runs nginx on `:80` in front of a node master
(`:3000`, lobby and page) and `NUM_WORKERS` node game workers (`:3001` and up).
There is no database, no Redis and no volume: every lobby and live game is held
in the pod's memory, and a restart ends them all.

That is also why the Deployment is pinned to `replicas: 1` with a `Recreate`
strategy. A game id routes to its worker by `hash % NUM_WORKERS` inside one pod,
so a second pod behind the same Service would receive WebSockets for games it
does not have.

`NUM_WORKERS=1`: one worker process holds every game, however many there are.
More workers only add CPU parallelism, one core each, for many concurrent games.

Measured idle at `NUM_WORKERS=1`: 310 to 400Mi for the container, with the
server's empty public lobbies opening and closing. Each extra worker adds about
150Mi. Memory grows with live games, since each keeps its full turn history. The
requests and limits in `base/openfront.yaml` are sized for one worker; resize
them together with `NUM_WORKERS`.

## Standalone mode, and why `GAME_ENV=dev`

The server depends on a closed-source OpenFront API at `https://api.<DOMAIN>`
for accounts, cosmetics, ranked queues and server registration. With
`GAME_ENV=prod` or `staging` it refuses anonymous players ("persistent ID not
allowed in production") and verifies every join against that API, so without the
API nobody can join.

`base/` therefore sets `GAME_ENV=dev`, the only mode that is playable
standalone. What that changes:

- Anonymous players join; Turnstile and join verification are skipped. The page
  still needs a site key, so it carries Cloudflare's always-pass test key.
- **A public lobby starts 5 seconds after it opens**, instead of 2 minutes.
  Private lobbies (the host starts them) and singleplayer are unaffected, so
  this setup suits playing with friends rather than public matchmaking.
- The three-connections-per-IP and one-client-per-account checks are off.
- OpenTelemetry export is off, whatever `OTEL_*` says.
- Calls to the API fail and are logged as errors, such as
  `Cosmetics HTTP error` and `Error polling 1v1 lobby`. They are harmless: the
  page, lobbies and games work without them.

`SUBDOMAIN`, `GAME_HOST`, `SITE_HOST` and `GAME_DOMAIN` are deliberately unset. The
first two give the server a public host, and a server with one registers with the
API and schedules no public lobbies until the API marks it open, which a
standalone deployment never gets.

## Building the image

`.github/workflows/k8s-image.yml` builds the repository's `Dockerfile` on every
push to `main` that touches more than `k8s/`, docs or Markdown, and pushes it to
Docker Hub twice: as `xavierclavel/openfront:latest` and as
`xavierclavel/openfront:<commit SHA>`. It runs only in a repository owned by
`XavierClavel`, so it stays inert in upstream `openfrontio/OpenFrontIO`, which has
no Docker Hub credentials for it and builds its own images.

Before building, it runs `selfhost/apply.sh`, which replaces OpenFront's
proprietary assets and renames the game to "PictaFront", as the license
requires of a modified version. See `selfhost/README.md`.

It does not deploy. After a build, restart the pod to pull the new `latest`:

```sh
kubectl -n openfront rollout restart deployment/openfront
```

It builds `linux/amd64` only (`PLATFORMS` in the workflow). That has to match the
cluster node, or the pod fails with `exec format error`.

### Public or private Docker Hub repository

Either works. Because of the swap above, the image carries none of OpenFront's
proprietary files, only the AGPL code and openly licensed assets, so publishing
it redistributes nothing restricted. Docker Hub creates `xavierclavel/openfront`
on first push with the account's default visibility; create it first to choose.

The Deployment references a pull secret named `dockerhub-pull` (see the table
below), needed only for a private repository. If the secret is missing, kubelet
logs a warning and pulls anonymously.

### Repository setup

Two secrets, under _Settings → Secrets and variables → Actions_ of the fork:

| Secret               | Value                                                          |
| -------------------- | -------------------------------------------------------------- |
| `DOCKERHUB_USERNAME` | `xavierclavel`                                                 |
| `DOCKERHUB_TOKEN`    | A Docker Hub personal access token with **Read & Write** scope |

To build by hand instead, see "Building by hand" in `selfhost/README.md`: the
asset swap rewrites the working tree, so it runs in a throwaway worktree.

## Rendering and applying

```sh
kubectl kustomize k8s/overlays/prod # render, no cluster needed
kubectl diff -k k8s/overlays/prod
kubectl apply -k k8s/overlays/prod

# after pushing a new :latest
kubectl -n openfront rollout restart deployment/openfront
```

The site is served at `pictafront.xavier.cl`, written once as `DOMAIN` in
`overlays/prod/kustomization.yaml`. That value becomes the server's `DOMAIN` and,
through `replacements`, the Ingress host and its certificate's name, so they
cannot drift apart. **Its DNS record must point at the cluster before the first
apply**: cert-manager requests the certificate as soon as the Ingress exists, and
the kubeconfig README's advice to try `letsencrypt-staging` first for a new
domain applies.

`base/` carries no image tag on purpose: `overlays/prod/kustomization.yaml` is the
single place the deployed version is recorded. The server environment comes from
a `configMapGenerator`, so its name carries a content hash and changing any value
rolls the pod.

## Config this tree does not contain

| Object              | Kind   | Consumed by                                                                         |
| ------------------- | ------ | ----------------------------------------------------------------------------------- |
| `openfront-secrets` | Secret | the app (`envFrom`, optional): `API_KEY`, `ADMIN_BOT_API_KEY`, `OTEL_*`, etc.       |
| `openfront-tls`     | Secret | Ingress TLS; written by cert-manager from the Ingress's `cluster-issuer` annotation |
| `dockerhub-pull`    | Secret | kubelet, to pull a private `xavierclavel/openfront` (`imagePullSecrets`)            |

Standalone mode needs neither key, so `openfront-secrets` is optional and the pod
starts without it. Create both by hand, never through a generator in this tree:

```sh
kubectl -n openfront create secret generic openfront-secrets \
  --from-literal=ADMIN_BOT_API_KEY=...

# A Read-only Docker Hub token, separate from the CI one.
kubectl -n openfront create secret docker-registry dockerhub-pull \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=xavierclavel --docker-password=<read-only token>
```

## CI

Two workflows, both in `.github/workflows/`:

- **`k8s-image.yml`** builds and pushes the image; see
  [Building the image](#building-the-image).
- **`manifests.yml`** runs on any pull request or push touching `k8s/**`:
  1. `kustomize build` the overlay.
  2. `kubeconform -strict` against the Kubernetes schemas.
  3. Rejects a `kind: Secret` in the render, any untagged image, and any
     `:latest` except the app's own `openfront` image.

There is no deploy job: nothing here talks to the cluster.

## Known issues

- **nginx starts one worker process per CPU of the node**, not of the pod: the
  image's `/etc/nginx/nginx.conf` is Debian's, with `worker_processes auto`. On a
  12-CPU host that is 12 workers at about 6Mi each. Harmless, but it grows with
  the node.
- **The container runs as root** (supervisord starts nginx, then the node server
  as `node`). A namespace enforcing the `restricted` Pod Security Standard
  rejects it; k3s enforces nothing by default.
- **`imagePullPolicy: Always` on `:latest`** means the manifests do not say which
  build runs. The pod does: `/commit.txt` serves the commit SHA, which is also
  the build's immutable tag. Roll back with
  `kubectl -n openfront set image deployment/openfront openfront=xavierclavel/openfront:<sha>`;
  the next apply puts `latest` back.
