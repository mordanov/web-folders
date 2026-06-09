# Docker Compose → k3s Migration Plan

**Last Updated:** June 2026
**Current State:** ~32 services in a single monolithic `docker-compose.yaml` on one VPS
**Target State:** k3s single-node cluster (expandable to multi-node), per-app namespaces,
declarative replica management, cert-manager TLS, Prometheus/Grafana observability
**Estimated Timeline:** 4–6 weeks (phased, old Compose runs in parallel until cutover)

---

## 1. Why k3s (and not Swarm)

| Concern | Docker Swarm | k3s |
|---------|-------------|-----|
| Replica management | `docker service scale` | `kubectl scale` + HPA (autoscale) |
| Observability | Manual Prometheus scrape config | kube-prometheus-stack, ServiceMonitor CRDs |
| Ingress & TLS | nginx + certbot container | Traefik (bundled) + cert-manager |
| Secrets | `.env` files / Docker Secrets | Kubernetes Secrets, easy to swap for Vault/Sealed Secrets |
| Industry adoption | Declining (Docker Inc. deprioritised) | K8s ecosystem, widely documented |
| Single-node overhead | Very low | Low (k3s binary is ~70 MB, single process) |
| Multi-node expansion | Swarm join token | `k3s agent`, then `kubectl` everywhere |
| GitOps readiness | Manual `docker stack deploy` | Flux / ArgoCD native support |

k3s is the lightweight Kubernetes distribution — one binary, no etcd (uses SQLite by default,
upgradeable to embedded etcd for HA), includes Traefik ingress and local-path-provisioner
out of the box.

---

## 2. Target Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  VPS (single node, k3s server)                                        │
│                                                                        │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  Traefik (IngressController, replaces nginx)                   │  │
│  │  • Port 80 / 443                                               │  │
│  │  • cert-manager issues Let's Encrypt certs per Ingress         │  │
│  └──────────────────┬─────────────────────────────────────────────┘  │
│                     │  routes by hostname                             │
│  ┌──────────────────▼─────────────────────────────────────────────┐  │
│  │  Namespaces (one per app group)                                 │  │
│  │                                                                  │  │
│  │  infra/         → postgres, pgview                              │  │
│  │  recipes/        → recipes-backend (2 replicas), frontend       │  │
│  │  auth/           → auth-backend (2+), auth-frontend             │  │
│  │  archive/        → archive-backend (2+), archive-frontend       │  │
│  │  budget/         → budget-backend, budget-frontend              │  │
│  │  … (one per site from sites.yaml)                               │  │
│  │  monitoring/     → kube-prometheus-stack, Loki, Grafana         │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│  PersistentVolumes (local-path, same data dirs as before)             │
└──────────────────────────────────────────────────────────────────────┘
```

### Key concept changes vs. docker-compose

| Compose concept | k3s equivalent |
|-----------------|---------------|
| `service:` | `Deployment` + `Service` |
| `expose:` | `Service` (ClusterIP) |
| `ports:` | `Service` (NodePort / LoadBalancer) or `Ingress` |
| `volumes:` | `PersistentVolumeClaim` |
| `environment:` | `ConfigMap` (non-secret) + `Secret` (passwords/keys) |
| `depends_on:` | Readiness probes + init containers |
| `deploy.replicas:` | `spec.replicas:` in Deployment |
| `healthcheck:` | `livenessProbe` + `readinessProbe` |
| nginx + certbot | Traefik IngressController + cert-manager |
| sites.yaml loop | One `Ingress` resource per site |

---

## 3. Prerequisites & Tooling

```bash
# On your local machine (Mac)
brew install kubectl helm k9s

# k9s = terminal UI for kubernetes, highly recommended
# helm = package manager for k8s apps (prometheus-stack, cert-manager, etc.)

# On VPS
curl -sfL https://get.k3s.io | sh -
# → installs k3s server, starts it as a systemd service
# → bundles: kubectl, crictl, Traefik, local-path-provisioner, CoreDNS

# Copy kubeconfig to your Mac
scp user@vps:/etc/rancher/k3s/k3s.yaml ~/.kube/config-k3s
# Edit the file: change "127.0.0.1" to your VPS IP
export KUBECONFIG=~/.kube/config-k3s
kubectl get nodes   # should show 1 node, Ready
```

---

## 4. Repository Structure (target)

```
web-folders/
├── k8s/
│   ├── namespaces.yaml          # all namespace definitions
│   ├── infra/
│   │   ├── postgres.yaml        # StatefulSet + Service + PVC
│   │   ├── pgview.yaml
│   │   └── secrets.yaml         # DB passwords (git-ignored, or Sealed)
│   ├── cert-manager/
│   │   └── cluster-issuer.yaml  # Let's Encrypt ClusterIssuer
│   ├── recipes/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── ingress.yaml
│   │   └── secret.yaml
│   ├── auth/
│   ├── archive/
│   ├── budget/
│   ├── reminders/
│   ├── admin-routine/
│   ├── news/
│   ├── poetry/
│   ├── servinga/
│   ├── portuguese-expenses/
│   ├── ticket-manager/
│   ├── home-resources/
│   └── monitoring/
│       ├── kube-prometheus-stack-values.yaml
│       └── loki-values.yaml
├── docker-compose.yaml          # kept as reference until cutover
└── documentation/
    └── K3S_MIGRATION_PLAN.md    # this file
```

---

## 5. Phase 0 — k3s Setup & Validation (Days 1–2)

### 5.1 Install k3s

```bash
# On VPS — install k3s server with Traefik enabled (default)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --disable=servicelb \
  --tls-san=<your-vps-ip> \
  --tls-san=<your-domain>" sh -

# Verify
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A

# Allow your normal user to use kubectl
sudo cp /etc/rancher/k3s/k3s.yaml /home/$USER/k3s.yaml
sudo chown $USER /home/$USER/k3s.yaml
export KUBECONFIG=/home/$USER/k3s.yaml
```

> **Note on servicelb:** k3s bundles its own load balancer (Klipper ServiceLB).
> We disable it because Traefik handles external traffic. If you need bare-metal
> LoadBalancer services later, use MetalLB instead.

### 5.2 Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true

kubectl get pods -n cert-manager   # all 3 should be Running
```

### 5.3 Create Let's Encrypt ClusterIssuer

```yaml
# k8s/cert-manager/cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your@email.com          # ← change this
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: traefik
```

```bash
kubectl apply -f k8s/cert-manager/cluster-issuer.yaml
kubectl get clusterissuer letsencrypt-prod   # READY=True
```

### 5.4 Create namespaces

```yaml
# k8s/namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: infra
---
apiVersion: v1
kind: Namespace
metadata:
  name: recipes
---
apiVersion: v1
kind: Namespace
metadata:
  name: auth
---
# ... repeat for: archive, budget, reminders, admin-routine,
#     news, poetry, servinga, portuguese-expenses, ticket-manager,
#     home-resources, monitoring
```

```bash
kubectl apply -f k8s/namespaces.yaml
kubectl get namespaces
```

---

## 6. Phase 1 — Database (StatefulSet) (Days 2–3)

PostgreSQL must be a `StatefulSet` (not `Deployment`) because it has stable storage identity.
Pin it to the node with a `nodeSelector` so its PVC stays local.

```yaml
# k8s/infra/postgres.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: infra
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path      # k3s default provisioner
  resources:
    requests:
      storage: 50Gi
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: infra
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          envFrom:
            - secretRef:
                name: postgres-secrets
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: init-scripts
              mountPath: /docker-entrypoint-initdb.d
              readOnly: true
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "recipes_user", "-d", "recipes"]
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "recipes_user", "-d", "recipes"]
            initialDelaySeconds: 30
            periodSeconds: 10
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-data
        - name: init-scripts
          configMap:
            name: postgres-init-scripts
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: infra
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
  type: ClusterIP
```

Cross-namespace connection string: `postgres.infra.svc.cluster.local:5432`

```yaml
# k8s/infra/secrets.yaml  (git-ignored — use Sealed Secrets in prod)
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secrets
  namespace: infra
type: Opaque
stringData:
  POSTGRES_DB: recipes
  POSTGRES_USER: recipes_user
  POSTGRES_PASSWORD: change-me-recipes-db
  # ... all other DB env vars from docker-compose
```

```bash
kubectl apply -f k8s/infra/secrets.yaml
kubectl apply -f k8s/infra/postgres.yaml
kubectl get pods -n infra    # postgres-0 should be Running
```

---

## 7. Phase 2 — First App: Recipes (Template for All) (Days 3–4)

This section is the template to replicate for every app.

### 7.1 Secret

```yaml
# k8s/recipes/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: recipes-secrets
  namespace: recipes
type: Opaque
stringData:
  DATABASE_URL: "postgresql+asyncpg://recipes_user:change-me@postgres.infra.svc.cluster.local:5432/recipes"
  SECRET_KEY: "change-me-recipes-secret"
  USER1_PASSWORD: "change-me-password1"
  USER2_PASSWORD: "change-me-password2"
  SERVICE_USER_PASSWORD: "change-me-recipes-service-password"
```

### 7.2 Deployment + Service

```yaml
# k8s/recipes/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: recipes-backend
  namespace: recipes
spec:
  replicas: 2                       # enforced, not a suggestion
  selector:
    matchLabels:
      app: recipes-backend
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0             # zero-downtime update
      maxSurge: 1
  template:
    metadata:
      labels:
        app: recipes-backend
    spec:
      containers:
        - name: recipes-backend
          image: your-registry/recipes-backend:latest  # or build locally
          envFrom:
            - secretRef:
                name: recipes-secrets
          env:
            - name: USER1_NAME
              value: mama
            - name: USER2_NAME
              value: papa
            - name: SERVICE_USER_NAME
              value: kitchen_service
            - name: OPENAI_API_KEY
              value: ""
          volumeMounts:
            - name: uploads
              mountPath: /app/uploads
            - name: documents
              mountPath: /app/documents
          readinessProbe:
            httpGet:
              path: /api/health
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /api/health
              port: 8000
            initialDelaySeconds: 30
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: uploads
          persistentVolumeClaim:
            claimName: recipes-uploads
        - name: documents
          persistentVolumeClaim:
            claimName: recipes-documents
---
apiVersion: v1
kind: Service
metadata:
  name: recipes-backend
  namespace: recipes
spec:
  selector:
    app: recipes-backend
  ports:
    - port: 8000
      targetPort: 8000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: recipes-frontend
  namespace: recipes
spec:
  replicas: 2
  selector:
    matchLabels:
      app: recipes-frontend
  template:
    metadata:
      labels:
        app: recipes-frontend
    spec:
      containers:
        - name: recipes-frontend
          image: your-registry/recipes-frontend:latest
          env:
            - name: BACKEND_ORIGIN
              value: http://recipes-backend.recipes.svc.cluster.local:8000
          readinessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: recipes-frontend
  namespace: recipes
spec:
  selector:
    app: recipes-frontend
  ports:
    - port: 3000
      targetPort: 3000
```

### 7.3 Ingress (replaces nginx vhost + certbot)

```yaml
# k8s/recipes/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: recipes
  namespace: recipes
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.middlewares: default-redirect-https@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - recipes.mainpage.com
      secretName: recipes-tls
  rules:
    - host: recipes.mainpage.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: recipes-backend
                port:
                  number: 8000
          - path: /
            pathType: Prefix
            backend:
              service:
                name: recipes-frontend
                port:
                  number: 3000
```

### 7.4 PVCs

```yaml
# k8s/recipes/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: recipes-uploads
  namespace: recipes
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: recipes-documents
  namespace: recipes
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
```

```bash
kubectl apply -f k8s/recipes/
kubectl get pods -n recipes
kubectl get ingress -n recipes
```

---

## 8. Replica Management

### Scale a deployment

```bash
# Immediately scale archive-backend to 4
kubectl scale deployment archive-backend -n archive --replicas=4

# Watch the rollout
kubectl rollout status deployment/archive-backend -n archive

# See pod distribution
kubectl get pods -n archive -o wide
```

### Horizontal Pod Autoscaler (automatic scaling)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: archive-backend-hpa
  namespace: archive
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: archive-backend
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

```bash
kubectl apply -f k8s/archive/hpa.yaml
kubectl get hpa -n archive    # shows current/target replicas
```

### Services with existing replicas in docker-compose

| Service | compose replicas | k8s initial | HPA? |
|---------|-----------------|-------------|------|
| archive-backend | 2 | 2 | Yes (cpu 70%) |
| ticket-manager-backend | 2 | 2 | Yes (cpu 70%) |
| auth-backend | 1 | 2 | Yes (critical path) |
| recipes-backend | 1 | 2 | Optional |
| All frontends | 1 | 1–2 | No (static, low cpu) |

---

## 9. Rolling Updates & Image Management

### Build and push images

For each service you need images in a registry. Options:
1. **Docker Hub** (public, free tier): `docker.io/yourname/recipes-backend`
2. **GitHub Container Registry**: `ghcr.io/yourname/recipes-backend`
3. **Local registry on VPS** (simplest for private repos):

```bash
# Run a local registry on the VPS
docker run -d -p 5000:5000 --restart=always --name registry registry:2

# Tag and push
docker build -t localhost:5000/recipes-backend:v1 ../family-kitchen-recipes/backend
docker push localhost:5000/recipes-backend:v1

# k3s must trust it (insecure by default on localhost:5000)
# Add to /etc/rancher/k3s/registries.yaml:
mirrors:
  "localhost:5000":
    endpoint:
      - "http://localhost:5000"
```

### Deploy a new version

```bash
# Rebuild and push new image
docker build -t localhost:5000/recipes-backend:v2 ../family-kitchen-recipes/backend
docker push localhost:5000/recipes-backend:v2

# Update deployment (triggers rolling update, zero downtime with maxUnavailable:0)
kubectl set image deployment/recipes-backend \
  recipes-backend=localhost:5000/recipes-backend:v2 \
  -n recipes

# Watch rollout
kubectl rollout status deployment/recipes-backend -n recipes

# Instant rollback if something breaks
kubectl rollout undo deployment/recipes-backend -n recipes
```

---

## 10. Observability Stack (kube-prometheus-stack)

This replaces the hand-rolled `servinga-prometheus` container with a production-grade
Prometheus + Grafana + Alertmanager stack, plus automatic scraping of all k8s workloads.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install (includes Prometheus, Grafana, node-exporter, kube-state-metrics, Alertmanager)
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values k8s/monitoring/kube-prometheus-stack-values.yaml
```

```yaml
# k8s/monitoring/kube-prometheus-stack-values.yaml
grafana:
  adminPassword: change-me-grafana
  ingress:
    enabled: true
    ingressClassName: traefik
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
    hosts:
      - grafana.mainpage.com
    tls:
      - secretName: grafana-tls
        hosts:
          - grafana.mainpage.com

prometheus:
  prometheusSpec:
    retention: 30d
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 20Gi

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 2Gi

# node-exporter and kube-state-metrics enabled by default
nodeExporter:
  enabled: true
kubeStateMetrics:
  enabled: true
```

### Scrape your own app metrics

Add a `ServiceMonitor` for any service that exposes Prometheus metrics:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: recipes-backend
  namespace: recipes
  labels:
    release: kube-prometheus-stack    # must match helm release name
spec:
  selector:
    matchLabels:
      app: recipes-backend
  endpoints:
    - port: "8000"
      path: /metrics
      interval: 30s
```

### Loki (log aggregation)

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set promtail.enabled=true \
  --set loki.persistence.enabled=true \
  --set loki.persistence.storageClassName=local-path \
  --set loki.persistence.size=10Gi
```

Promtail auto-discovers all pod logs and ships them to Loki.
In Grafana: add Loki data source → `http://loki.monitoring.svc.cluster.local:3100`

---

## 11. Migration Checklist

### Phase 0 — k3s + cert-manager
- [ ] k3s installed and node is `Ready`
- [ ] `kubeconfig` working from local Mac
- [ ] cert-manager installed, `ClusterIssuer` `READY=True`
- [ ] Namespaces created
- [ ] k9s installed and showing cluster

### Phase 1 — Database
- [ ] `postgres-secrets` Secret applied in `infra` namespace
- [ ] `postgres-init` ConfigMap applied (init SQL scripts)
- [ ] PostgreSQL StatefulSet running (`postgres-0 Running`)
- [ ] Can exec into pod and `psql` successfully
- [ ] Old Compose postgres still running (parallel)

### Phase 2 — First app (recipes)
- [ ] Images built and pushed to registry
- [ ] Secrets and PVCs applied
- [ ] Deployment shows 2/2 replicas Ready
- [ ] Ingress shows `ADDRESS` (Traefik assigned)
- [ ] TLS cert issued (`kubectl get certificate -n recipes`)
- [ ] App accessible at `https://recipes.mainpage.com`
- [ ] Functional smoke test passed

### Phase 3 — All apps
- [ ] auth (2 replicas, tested)
- [ ] archive (2 replicas)
- [ ] budget, reminders, admin-routine
- [ ] news, poetry, servinga
- [ ] portuguese-expenses, ticket-manager, home-resources
- [ ] pgview (infra namespace, Ingress at pgview.admin.mainpage.com)
- [ ] Rolling update tested on one service (zero downtime confirmed)

### Phase 4 — Observability
- [ ] kube-prometheus-stack deployed
- [ ] Grafana accessible at `https://grafana.mainpage.com`
- [ ] Loki installed, logs visible in Grafana
- [ ] Node dashboard shows CPU/memory/disk
- [ ] All app pods show up in kube-state-metrics

### Cutover
- [ ] All health checks green on k3s side
- [ ] DNS pointing to VPS (same IP, no change needed)
- [ ] `docker compose down` — old stack stopped
- [ ] Verify all apps still working
- [ ] Remove old Compose containers and images to free disk

---

## 12. Pitfalls Specific to This Setup

### Pitfall 1: Cross-namespace DB connections

Services connect to postgres via full DNS:
`postgres.infra.svc.cluster.local:5432`
Not just `postgres` or `recipes-db` as in Compose.

Update every `DATABASE_URL` secret accordingly.

### Pitfall 2: local-path PVCs are node-local

`local-path` PVCs cannot be moved to another node.
If you add a second node, DB and upload PVCs must stay on the original node via `nodeSelector`:

```yaml
spec:
  nodeSelector:
    kubernetes.io/hostname: <your-vps-hostname>
```

Run `kubectl get nodes` to get the hostname value.

### Pitfall 3: Traefik strips /api prefix by default

If your backend expects `/api/v1/health` but Traefik routes `/api` → backend,
Traefik passes the full path by default (no stripping). Verify with:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik
```

Use `traefik.ingress.kubernetes.io/router.middlewares` to add a StripPrefix middleware
if stripping is needed.

### Pitfall 4: Archive-backend uses S3 required vars

`archive-backend` has `:?` required vars (`ARCHIVE_S3_ENDPOINT_URL` etc.).
These must be in the Secret before the Deployment is applied — pod will crash-loop otherwise.

### Pitfall 5: admin-routine mounts docker.sock

`admin-routine-backend` mounts `/var/run/docker.sock` to manage Docker containers.
In k3s this socket doesn't exist (k3s uses containerd). Options:
- Mount `/run/k3s/containerd/containerd.sock` and adapt the admin-routine code to use the containerd API
- Keep admin-routine on Compose and route it via a separate port
- Replace with a k8s-native approach (access k8s API via a ServiceAccount)

This is the one service that needs special handling. Plan it as a separate sub-task.

### Pitfall 6: servinga-prometheus uses host network

The existing `servinga-prometheus` runs with `network_mode: host` to scrape node metrics.
In k3s this is replaced entirely by `node-exporter` (DaemonSet, one per node).
No host-network mode needed.

### Pitfall 7: Image build during Compose vs. pre-built in k3s

`docker compose` builds images on the fly from `build.context`.
k3s pulls pre-built images. You must build and push every image to a registry before deploying.
Set up a simple CI step (GitHub Actions) to build + push on every push to main.

---

## 13. Secrets Management (Production Hardening)

The initial approach (plain `Secret` in YAML, git-ignored) is a reasonable start.
Upgrade path:

1. **Sealed Secrets** (recommended first step):
   ```bash
   helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system
   # Encrypt a secret so it's safe to commit to git
   kubeseal --format yaml < k8s/recipes/secret.yaml > k8s/recipes/sealed-secret.yaml
   # sealed-secret.yaml can be committed; only your cluster can decrypt it
   ```

2. **External Secrets Operator** + Vault or AWS Secrets Manager (later)

---

## 14. CI/CD Integration (GitHub Actions)

```yaml
# .github/workflows/deploy-k3s.yml
name: Build & Deploy to k3s

on:
  push:
    branches: [main]

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build and push recipes-backend
        run: |
          docker build -t ${{ secrets.REGISTRY }}/recipes-backend:${{ github.sha }} \
            ../family-kitchen-recipes/backend
          docker push ${{ secrets.REGISTRY }}/recipes-backend:${{ github.sha }}

      - name: Deploy to k3s
        env:
          KUBECONFIG_DATA: ${{ secrets.KUBECONFIG }}
        run: |
          echo "$KUBECONFIG_DATA" > kubeconfig.yaml
          kubectl --kubeconfig kubeconfig.yaml set image \
            deployment/recipes-backend \
            recipes-backend=${{ secrets.REGISTRY }}/recipes-backend:${{ github.sha }} \
            -n recipes
          kubectl --kubeconfig kubeconfig.yaml rollout status \
            deployment/recipes-backend -n recipes
```

---

## 15. Timeline

```
Week 1
├── Day 1:   k3s install, cert-manager, namespaces, local registry
├── Day 2:   postgres StatefulSet + validation
├── Day 3–4: recipes app (template for all others)
├── Day 5:   auth app (2 replicas, test HPA)

Week 2
├── Day 1:   archive, budget, reminders
├── Day 2:   admin-routine (special: docker.sock issue — plan separately)
├── Day 3:   news, poetry, servinga (note: servinga-prometheus → kube-prometheus)
├── Day 4:   portuguese-expenses, ticket-manager, home-resources
├── Day 5:   pgview in infra namespace, all ingresses validated

Week 3
├── Day 1–2: kube-prometheus-stack + Loki + Grafana dashboards
├── Day 3:   HPA for archive, ticket-manager, auth
├── Day 4:   Load test + rolling update dry-run
├── Day 5:   Sealed Secrets migration

Week 4
├── Day 1:   GitHub Actions CI/CD for all services
├── Day 2–3: Parallel run validation (Compose + k3s both serving)
├── Day 4:   DNS cutover (if needed) / Compose shutdown
├── Day 5:   Runbooks, documentation, buffer
```

---

## 16. Useful Commands Reference

```bash
# Cluster overview
kubectl get nodes
k9s                                     # interactive TUI

# Deployments
kubectl get deployments -A
kubectl get pods -n recipes -o wide
kubectl describe pod <pod-name> -n recipes

# Scale
kubectl scale deployment archive-backend -n archive --replicas=4

# Rolling update + rollback
kubectl set image deployment/recipes-backend recipes-backend=image:v2 -n recipes
kubectl rollout status deployment/recipes-backend -n recipes
kubectl rollout undo deployment/recipes-backend -n recipes

# Logs
kubectl logs -f deployment/recipes-backend -n recipes
kubectl logs -f deployment/recipes-backend -n recipes --all-containers

# Exec into a pod
kubectl exec -it deployment/postgres -n infra -- psql -U recipes_user -d recipes

# Ingress + TLS
kubectl get ingress -A
kubectl get certificate -A              # cert-manager issued certs

# Monitoring
kubectl get hpa -A
kubectl top pods -A                     # requires metrics-server (bundled in k3s)
kubectl top nodes

# Events (best debugging tool)
kubectl get events -n recipes --sort-by='.lastTimestamp'
```

---

## 17. Resources

- **k3s docs**: https://docs.k3s.io
- **cert-manager**: https://cert-manager.io/docs
- **kube-prometheus-stack**: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- **Sealed Secrets**: https://github.com/bitnami-labs/sealed-secrets
- **k9s**: https://k9scli.io
- **Traefik + k3s**: https://doc.traefik.io/traefik/providers/kubernetes-ingress
