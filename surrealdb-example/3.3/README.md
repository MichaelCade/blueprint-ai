# SurrealDB 3.3 — Kasten blueprint (keeper PVC pattern)

> Validated end to end through Kasten (Steps 1–5 of [AGENTS.md](../../AGENTS.md)), including a
> restore from the restore point **exported to object storage**, and the export deduplication
> was measured (Step 6).

## Versions

| Component | Version |
|---|---|
| Kubernetes | `1.34.1` (Talos `1.12.6`, bare metal) |
| Kasten | `9.0.8` (Helm) |
| Helm chart | `surrealdb/surrealdb 0.5.0` |
| SurrealDB | `3.3.5`, storage engine SurrealKV |
| Storage | Rook Ceph RBD (`ceph-block`), VolumeSnapshotClass `rook-ceph-block-snapshot` |
| Keeper image | `surrealdb/surrealdb:v3.3.5-dev` (upstream, not rebuilt) |

## Pattern

**Pattern 4 — database dump on a permanent keeper PVC.**

- SurrealDB has no command to pause writes, so a snapshot of its data volume is only
  crash-consistent.
- `surreal export` reads the whole database inside **one transaction**, so the file it
  writes is a consistent point-in-time copy even while clients keep writing.
- The production SurrealDB image has no shell (it is built on Chainguard `glibc-dynamic`), so
  nothing can run `sync` inside the SurrealDB pod. A keeper pod that runs the `-dev` image of the
  same version has the `surreal` CLI **and** a shell. It mounts its own PVC permanently, and
  Kasten snapshots that PVC.

```
                  surrealdb-test namespace
  ┌──────────────────────┐   HTTP    ┌──────────────────────────┐
  │ surrealdb            │ ◄──────── │ surrealdb-keeper         │
  │ v3.3.5 (no shell)    │  export / │ v3.3.5-dev (sh + surreal)│
  │ PVC surrealdb        │  import   │ PVC surrealdb-keeper     │
  │ crash-consistent     │           │ /backup/surrealdb/*.surql│
  └──────────────────────┘           └──────────────────────────┘
             ▲                                    ▲  KubeExec
             └──── Kasten snapshots both PVCs ────┘  backupPrehook / restorePosthook
```

## Step 2 — Deploy SurrealDB and create test data

### Deploy

The root password is generated into a Secret. The Helm values read it from there, so no
credential is written in a values file.

```bash
kubectl create ns surrealdb-test
kubectl -n surrealdb-test create secret generic surrealdb-root \
  --from-literal=username=root --from-literal=password="$(openssl rand -hex 16)"

helm repo add surrealdb https://helm.surrealdb.com
helm repo update surrealdb
helm install surrealdb surrealdb/surrealdb --version 0.5.0 \
  -n surrealdb-test -f surrealdb-values.yaml --wait
```

[surrealdb-values.yaml](surrealdb-values.yaml) does five things on top of the chart defaults:

| Setting | Why |
|---|---|
| `image.tag: v3.3.5` | The chart still defaults to SurrealDB 2.6. |
| `surrealdb.path: surrealkv:///data/srdb` | The chart default is `memory`, which keeps nothing on disk. SurrealKV is also the only on-disk engine in SurrealDB 4. |
| `strategy: Recreate` | One pod with a ReadWriteOnce volume. With a rolling update the new pod waits for a volume the old pod still holds. |
| `persistence` on `ceph-block` | The data PVC (`surrealdb`, 2 GiB). |
| Pod and container security context | Meets the Kubernetes `restricted` Pod Security profile. `runAsUser: 65532` is required: the image names its user `nonroot` instead of giving a number, and Kubernetes refuses `runAsNonRoot` when it cannot check the number. |

> **Storage class**: `ceph-block` is the Rook Ceph RBD CSI storage class used in our test
> environment. Replace it with a storage class that supports CSI snapshots on your cluster
> (for example, `ebs-sc` on EKS, `managed-csi` on AKS, `standard-rwo` on GKE, and so on).
> The class must have a matching `VolumeSnapshotClass` registered with Kasten.
> Do **not** use legacy in-tree classes (for example, `gp2` on AWS) — they do not support CSI snapshots.

### Create the test data

A client pod runs the `-dev` image of the same SurrealDB version. The `-dev` image adds a shell
to the same `surreal` binary. Note that the binary is `/surreal` and is **not** on the `PATH`.

```bash
kubectl run surreal-client -n surrealdb-test --image=surrealdb/surrealdb:v3.3.5-dev --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"surreal-client","image":"surrealdb/surrealdb:v3.3.5-dev","command":["sleep","infinity"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"envFrom":[{"secretRef":{"name":"surrealdb-root"}}]}]}}'
kubectl wait -n surrealdb-test pod/surreal-client --for=condition=Ready

SQL='/surreal sql -e http://surrealdb:8000 -u "$username" -p "$password" --ns kasten --db test --hide-welcome'
kubectl exec -i -n surrealdb-test surreal-client -- sh -c "$SQL" < seed.surql
```

[seed.surql](seed.surql) (about 1.2 KB) creates namespace `kasten`, database `test`, and covers
everything a restore must bring back:

| Object | Content |
|---|---|
| `product` | Schemafull table, 5 records, unique index `product_name` |
| `customer` | Schemaless table, 3 records |
| `ordered` | 5 graph edges (`RELATE customer->ordered->product`) |
| `fn::order_total` | A stored function that follows the graph edges |

> The `surreal sql` CLI reads standard input **one line at a time**. A statement written over
> several lines produces a parse error for each partial line. Keep every statement on one line in
> files you pipe into it.

### Check the data

```bash
kubectl exec -i -n surrealdb-test surreal-client -- sh -c "$SQL --json" < verify.surql
```

Expected result (the `[]` lines before it are the comment lines):

```json
[{"alice_total":110,"bob_total":160,"chen_total":105,"customers":3,"has_index":true,"orders":5,"products":5}]
```

## Step 3 — Manual validation (no blueprint)

### Deploy the keeper

```bash
kubectl apply -f keeper.yaml
```

[keeper.yaml](keeper.yaml) creates the backup PVC `surrealdb-keeper` (1 GiB, `ceph-block`) and a
Deployment that keeps it mounted at `/backup`. The pod runs `surrealdb/surrealdb:v3.3.5-dev` and
does nothing until something execs into it. It reads the root credentials from the same Secret
as the server.

### Back up

```bash
kubectl exec -i -n surrealdb-test deploy/surrealdb-keeper -- sh -s < scripts/backup.sh
```

[scripts/backup.sh](scripts/backup.sh):

1. Lists every SurrealDB namespace and every database in it (`INFO FOR ROOT`, `INFO FOR NS`).
2. Runs `surreal export` for each database into `/backup/.staging/<ns>/<db>.surql`, and records
   size and SHA-256 in a `MANIFEST`.
3. Swaps the complete staging directory in as `/backup/surrealdb`. A run that fails half way
   leaves the previous dump in place.
4. Runs `sync` — the last write. Then re-reads every file against its checksum.

### What Step 3 proved

| Test | Result |
|---|---|
| **Export is consistent under writes.** A client committed transactions that each create `load_a:N` **and** `load_b:N`, at about 50 per second, on top of 20,000 pairs. Five exports ran during the writes. `load_b` is exported after `load_a`, so an export that is not one read transaction would contain more `load_b` than `load_a`. | All 5 exports: equal counts, equal highest ID (20,809 → 21,298). |
| **The dump survives the CSI snapshot.** Snapshot both PVCs, restore them to new PVCs. | All three files present, byte counts and checksums equal to the `MANIFEST`. |
| **Restore over damaged data.** After the backup: change a price, delete a customer (and so 2 graph edges), add a customer. Then run [scripts/restore.sh](scripts/restore.sh). | `verify.surql` returns the expected values. The added customer is gone. |
| **Restore into an empty SurrealDB.** Replace the data PVC by an empty one, keep only the keeper PVC. | Same result: the dump is enough on its own. |

### Restore

```bash
kubectl exec -i -n surrealdb-test deploy/surrealdb-keeper -- sh -s < scripts/restore.sh
```

[scripts/restore.sh](scripts/restore.sh) checks every file against the `MANIFEST` **before** it
touches the database, waits for SurrealDB to be ready, then for each database in the dump:
`REMOVE DATABASE`, `DEFINE DATABASE IF NOT EXISTS`, `surreal import`. Databases that are not in
the dump are not touched.

### Behaviour found in Step 3

| Behaviour | Consequence for the blueprint |
|---|---|
| `surreal sql` **exits 0 when a statement fails**. The error is a JSON string (`["The database 'main' already exists"]`); a success is `[null]`. | Scripts check the output, not the exit code. |
| SurrealDB 3 **re-creates the default database `main`** as soon as it is removed, so a plain `DEFINE DATABASE main` fails. | `DEFINE DATABASE IF NOT EXISTS`. |
| `surreal --help` prints default values, **including `SURREAL_PASS` from the environment**. | Never call `--help` in a blueprint: Kasten keeps phase output in its logs. |
| The `-dev` image has `sh`, `sed`, `awk`, `grep`, `sha256sum` and `sync`, but **no `jq`** and no `date +%N`. | JSON from `surreal sql --json` is parsed with `sed`. |
| A database export does **not** contain root-level or namespace-level users and access methods. | They come back with the data PVC (crash-consistent) or from the Helm Secret (the root user). See "What is not protected" below. |

### What is not protected by the dump

- **Root and namespace-level users and access methods** (`DEFINE USER … ON ROOT`,
  `… ON NAMESPACE`). Database-level users are in the dump. The root user is re-created from the
  `surrealdb-root` Secret on an empty instance.
- **Consistency across databases.** Each database is exported in its own transaction. Two
  databases are each consistent, but not at the same instant. Keep data that must agree in one
  database.
- **Incrementality.** Every backup is a full dump. How much of it the export re-uploads depends on
  where the changes are — see Step 6.

## Step 4 — The blueprint

### Prerequisites

| Requirement | Detail |
|---|---|
| SurrealDB Service | The keeper reaches SurrealDB at `http://surrealdb:8000` (`SURREAL_ENDPOINT` in [keeper.yaml](keeper.yaml)). That is the Service the chart creates for a release named `surrealdb`. Change it if your release has another name. |
| Root credentials | Secret `surrealdb-root` (`username`, `password`), read by both SurrealDB and the keeper. The blueprint itself reads no Secret. |
| Keeper | [keeper.yaml](keeper.yaml) deployed in the **same namespace** as SurrealDB, with the label `blueprint-ai/surrealdb-keeper: "true"`. |
| Keeper image | `surrealdb/surrealdb:v<same version as the server>-dev`. Upstream image, no Dockerfile to build. **Keep it at the server's version**: an export and import across versions is not supported. |

No custom image, no operator setting, no Helm value beyond [surrealdb-values.yaml](surrealdb-values.yaml).

### Install

```bash
kubectl apply -f blueprint.yaml -f blueprintbinding.yaml
```

[blueprintbinding.yaml](blueprintbinding.yaml) binds the blueprint to every Deployment labelled
`blueprint-ai/surrealdb-keeper: "true"`, in any namespace. The binding is on the **keeper**, never
on SurrealDB: the keeper is the pod the blueprint execs into. A second SurrealDB instance needs
its own keeper, and nothing in `kasten-io` changes.

### Blueprint actions

| Action | What it does |
|---|---|
| `backupPrehook` | `KubeExec` into the keeper. Lists every namespace and database, runs `surreal export` for each into a staging directory with a SHA-256 `MANIFEST`, swaps it in as `/backup/surrealdb`, runs `sync` (last), then re-reads every file against its checksum. Fails the backup on an empty export, an unexpected name, or a checksum mismatch. |
| `restorePosthook` | `KubeExec` into the keeper after Kasten has restored the PVCs and restarted the pods. Checks every file against the `MANIFEST` before it touches anything, waits for SurrealDB to be ready, then for each database in the dump: `REMOVE DATABASE`, `DEFINE DATABASE IF NOT EXISTS`, `surreal import`. |

There is no `backupPosthook`: the prehook pauses nothing, so there is nothing to undo.

The scripts inside [blueprint.yaml](blueprint.yaml) are copies of
[scripts/backup.sh](scripts/backup.sh) and [scripts/restore.sh](scripts/restore.sh), the versions
validated by hand in Step 3. **Change both or neither.**

### How the filesystem flush applies here

The keeper is the **only** writer during `backupPrehook`, and the blueprint runs `sync` in the
keeper as its last step, so the dump Kasten captures is on disk.

The SurrealDB data PVC is also in the restore point (the policy backs up the whole namespace),
but it is **not** flushed: the production image has no `sync`. That copy is crash-consistent.
SurrealKV recovered from it in Step 3, and the `restorePosthook` then replaces every database
with its dump in any case. The data PVC is in the restore point for what the dump does not
hold — see "What is not protected by the dump".

### Restore

No manual step is needed before a restore, in place or into a new namespace: Kasten scales the
workloads down, restores both PVCs, starts the pods again, and then runs `restorePosthook`.

Restore into a **new** namespace works as long as SurrealDB and the keeper are restored together
(they are, when you restore the whole application): the endpoint `http://surrealdb:8000` resolves
inside the namespace the keeper runs in.

## Step 5 — End-to-end test through Kasten

### Policy

[policy.yaml](policy.yaml) is an on-demand policy on namespace `surrealdb-test`: a backup, then an
export of the restore point to the `kasten-backups` Location profile. Replace the profile name
with yours.

```bash
kubectl apply -f policy.yaml
kubectl create -f - <<EOF
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RunAction
metadata:
  generateName: run-surrealdb-test-
  namespace: kasten-io
spec:
  subject: {kind: Policy, name: surrealdb-test-backup, namespace: kasten-io}
EOF
```

### Check the backup

```bash
kubectl get backupaction,exportaction -n surrealdb-test        # both Complete
kubectl exec -n surrealdb-test deploy/surrealdb-keeper -- cat /backup/surrealdb/TIMESTAMP
kubectl logs -n kasten-io deploy/kanister-svc --since=15m | grep -E 'exportToKeeper|Exported [0-9]+ database'
```

The phase output is in the **`kanister-svc`** log (on Kasten 9.0.8 it is not in the `executor`
log). Expected: `Completed phase exportToKeeper` and `Exported 3 database(s) at <time>`, with the
`TIMESTAMP` in the keeper equal to that time.

### Restore

Pick the **exported** restore point (label `k10.kasten.io/exportProfile`) to prove that the copy
in object storage is enough on its own:

```bash
kubectl get restorepoint -n surrealdb-test -L k10.kasten.io/exportProfile
kubectl create -f - --validate=false <<EOF
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RestoreAction
metadata:
  generateName: restore-surrealdb-
  namespace: surrealdb-test
spec:
  subject:
    apiVersion: apps.kio.kasten.io/v1alpha1
    kind: RestorePoint
    name: <EXPORTED_RESTORE_POINT>
    namespace: surrealdb-test
  targetNamespace: surrealdb-test
EOF
```

No `profile` field is needed on Kasten 9.x (see [AGENTS.md](../../AGENTS.md#triggering-restoreaction)).

### Result

| Check | Result |
|---|---|
| RunAction, BackupAction, ExportAction | `Complete` |
| `backupPrehook` | `Completed phase exportToKeeper`; dump timestamp `11:06:04Z`, during the backup |
| Exported restore point contents | PVCs `surrealdb` and `surrealdb-keeper` |
| Damage after the backup | `alice_total` 2058, Bob and his 2 orders deleted, `customer:mallory` added |
| RestoreAction (from the exported restore point) | `Complete` |
| `restorePosthook` | `Restoring the dump taken at 2026-11-17T11:06:04Z`, three databases imported, `Restore complete` |
| `verify.surql` after restore | `alice_total 110, bob_total 160, chen_total 105, customers 3, orders 5, products 5, has_index true` |
| `customer:mallory`, `product:1.price` | `null`, `25` |

## Step 6 — Export deduplication

Every backup writes a **full** dump. Kasten exports to object storage through Kopia, which splits
files into content-defined chunks and uploads only chunks it has not seen. So the question is not
"is the dump incremental" (it is not) but "how many chunks does a backup change".

### Dataset

30,000 records in a separate database `kasten/bulk`, about 1 KB each, with **random** content
(`rand::string(900)`, `rand::uuid`, random numbers), loaded in batches of 3,000:

```bash
for s in $(seq 1 3000 27001); do e=$((s+2999)); echo "FOR \$i IN $s..=$e { CREATE type::record('event', \$i) SET uid = rand::uuid::v4(), user = rand::string(12), amount = rand::float(0, 10000), qty = rand::int(1, 50), at = time::now(), payload = rand::string(900) };"; done \
  | kubectl exec -i -n surrealdb-test deploy/surrealdb-keeper -- sh -c '/surreal sql -e $SURREAL_ENDPOINT --ns kasten --db bulk --hide-welcome --json'
```

| Item | Size |
|---|---|
| Dump `kasten/bulk.surql` | 30.8 MiB (30 `INSERT` statements of 1,000 records, about 1.08 MB each) |
| SurrealDB data PVC (`usedBytes`) | 32.1 MiB |

### Measurement

Repository size = `migration/repo/<namespace-uid>/` + `migration/surrealdb-test-backup/kopia/`
on the export bucket, read with `aws s3 ls --recursive --summarize`. Kasten 9.0.8 reported **no**
`progressDetails` / `transferredBytes` on the data ExportAction, even read straight after the
run, so repository growth is the only figure.

Both PVCs are exported, so every figure below is the dump **plus** the SurrealKV data volume.

| Run | Change since previous run | Repository after | Growth | Growth / first export |
|---|---|---|---|---|
| 1 | 30,000 records loaded | 56.9 MiB | — | — |
| 2 | **1% scattered**: 300 random records rewritten | 86.0 MiB | **29.1 MiB** | **51%** |
| 3 | No change (control) | 86.4 MiB | 0.4 MiB | 0.7% |
| 4 | **1% contiguous**: `event:10001`–`event:10300` rewritten | 90.0 MiB | **3.6 MiB** | **6.4%** |

### What the numbers mean

- **Unchanged data costs almost nothing** (run 3). The export of unchanged data is byte-identical
  (same SHA-256 in the `MANIFEST`), and SurrealKV did not rewrite its files while idle.
- **Where the changes are matters more than how many there are** (runs 2 and 4, same 300
  records). `surreal export` writes records in key order. 300 random updates over 30,000 records
  is about 10 changed records in every 1,000-record `INSERT`, so every Kopia chunk of the dump
  contains a change and the whole dump is uploaded again. The same 300 updates on consecutive
  keys change one region of the file, and most chunks are reused.
- **What this means for your workload.**

  | Workload | Expected export cost per backup |
  |---|---|
  | Mostly appends with increasing keys (events, logs, time series) | Small: new data lands at the end of each table |
  | Updates spread across a large table (typical OLTP) | Close to a full dump: plan bandwidth and object storage for it |

  Record IDs generated by SurrealDB (`CREATE event` without an ID) are random, not increasing, so
  even an append-only workload behaves like the scattered case unless the application chooses
  ordered IDs (for example `ulid()`). This last point follows from runs 2 and 4; it was not measured separately.

The test database was removed after the measurement (`REMOVE DATABASE bulk;`).

## Clean up

```bash
kubectl delete pod surreal-client -n surrealdb-test --ignore-not-found
kubectl delete -f keeper.yaml --ignore-not-found
helm uninstall surrealdb -n surrealdb-test
kubectl delete ns surrealdb-test          # also deletes the data PVC and the Secret
kubectl delete restorepointcontent -l k10.kasten.io/appNamespace=surrealdb-test --wait=false   # Kasten does not support watch on this kind
kubectl delete -f policy.yaml -f blueprintbinding.yaml -f blueprint.yaml
```

## Initial prompt

> Deploy SurrealDB to our cluster using our existing storageclass, then run through these tests
> to create an application consistent snapshot and export of this SurrealDB database.
> (Follow-up: explore SurrealDB 3, and confirm 3 and maybe even 4 are also viable.)
