# postgres Helm chart

Helm chart for a standalone PostgreSQL 16 instance, managed via ArgoCD.

This replaces the Terraform-managed deployment in `kubernetes/terraform/postgres-sql`
(and its near-duplicate, `postgres-sql-migrate`). Those Terraform configs are left in
place but should no longer be applied once ArgoCD is syncing this chart, to avoid two
controllers fighting over the same resources. Once you've confirmed ArgoCD is managing
`postgres`, run `terraform destroy` in both `postgres-sql` and `postgres-sql-migrate`
(or fold anything `postgres-sql-migrate` still needs into this chart's values as a
second Application) and remove them.

## What changed vs. the Terraform version

This rebuild also fixes the issues found in the production-readiness review of the
Terraform config:

- **Deployment → StatefulSet** with a `volumeClaimTemplate`, instead of a Deployment
  bound to a manually created `hostPath` PV on NFS. Gives stable storage/network
  identity and a normal path to adding replicas later.
- **`pg_hba.conf` hardened**: no `trust` entries (the old config let anyone who could
  reach the pod's socket or loopback authenticate as *any* role with no password) and
  no unrestricted `0.0.0.0/0` MD5 replication line. Every connection now requires
  `scram-sha-256`.
- **Password is no longer hardcoded in a committed file.** The old `secret.tf` shipped
  a real (weak) password as a literal base64 string. `values.yaml` here ships an empty
  `secrets.password` and the chart refuses to render without one being supplied
  out-of-band. See **Secrets** below.
- **Namespace is actually wired up.** The old Terraform module declared a
  `kubernetes_namespace` variable that no resource ever referenced, so everything
  silently ran in `default`. This chart's `argocd-application.yaml` targets a
  dedicated `postgres` namespace with `CreateNamespace=true`.
- **Resource requests/limits, liveness/readiness probes (`pg_isready`), and a
  non-root `securityContext`** (`allowPrivilegeEscalation: false`, all capabilities
  dropped) were added — none of this existed in the Terraform deployment.

## What did *not* change

- **Service type is still `LoadBalancer`**, matching the current external-reachability
  setup, by request. This means Postgres is still reachable from outside the cluster —
  the difference is that every connection now requires a `scram-sha-256` password
  instead of the old config's `trust`/open-MD5 entries. If external access isn't a
  deliberate, ongoing requirement, switch `service.type` to `ClusterIP` and put any
  needed external access behind a VPN/bastion instead.
- **No backup mechanism.** The Terraform version had none, and this chart doesn't add
  one yet (`pg_dump`/WAL-archiving CronJob, or an operator like CloudNativePG). That's
  the biggest remaining operational gap — treat it as the next follow-up, especially
  since a StatefulSet's PVC is still a single copy of the data.

## Structure

```
.
├── Chart.yaml
├── values.yaml              # safe to commit — no secret values
├── templates/
│   ├── statefulset.yaml
│   ├── service.yaml          # headless (StatefulSet governance) + client-facing service
│   ├── configmap.yaml        # postgresql.conf / pg_hba.conf, driven by values.yaml
│   ├── secret.yaml           # requires secrets.password
│   └── _helpers.tpl
├── argocd-application.yaml   # ArgoCD Application pointing at this chart
└── README.md
```

## Secrets

`values.yaml` ships with an empty `secrets.password` so it's safe to commit. Do **not**
fill it in directly in `values.yaml`. Instead:

- Local/manual installs: `helm upgrade --install postgres . -f values.yaml -f values-secret.yaml`
  with an untracked `values-secret.yaml` (already excluded via `.helmignore`).
- ArgoCD: supply the secret value out-of-band — e.g. via a private overlay Application,
  an External Secrets Operator / Sealed Secrets setup populating the `postgres` Secret,
  or ArgoCD's own secret management integration. Don't commit a real password into
  `argocd-application.yaml`.

Generate a strong password rather than reusing the old `pgpassword` value, e.g.:

```bash
openssl rand -base64 24
```

## Deploy

Repo: https://github.com/rdavis542/postgres-helm

1. Supply `secrets.password` via one of the methods above.
2. Apply it:
   ```bash
   kubectl apply -f argocd-application.yaml
   ```
3. Verify:
   ```bash
   argocd app get postgres
   kubectl get pods -n postgres -l app=postgres
   ```

## Local testing without ArgoCD

```bash
helm lint .
helm template . -f values.yaml -f values-secret.yaml
helm upgrade --install postgres . -n postgres --create-namespace -f values.yaml -f values-secret.yaml
```

## Connecting

In-cluster clients (e.g. the `rest-easy` API) should connect via the Service DNS name:

```
postgres.postgres.svc.cluster.local:5432
```

adjusting the namespace segment if you deploy this chart under a different
`destination.namespace`.
