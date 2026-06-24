---
name: fix-stale-webhook-oids
description: Fixes Sequin webhooks broken when graph-node history pruning swaps a subgraph table (drops the old table, creates a new same-named one with a new OID), leaving the consumer pinned to a dead OID and showing the "No tables in publication" / no_tables_in_publication sink_configuration health notice. Re-adds the swapped table to the source publication, sets REPLICA IDENTITY FULL, and updates Sequin's stored include_table_oids. Use when user says "fix stale oids", "fix stale webhook oids", "no tables in publication", "webhook pinned to dead oid", "fix prune-swapped webhooks", or a Sequin sink page shows "Error: Sink configuration / No tables in publication".
---

# Fix Stale Webhook OIDs (graph-node prune-swap recovery)

Sequin `sink_consumers` pin to a **source-table OID** (`source->include_table_oids`), not to `schema.name`. graph-node history pruning with the **rebuild/copy strategy** does: CREATE new table → copy retained rows → DROP old → RENAME new to the original name. The rename gives the table a **new OID** and drops the old one. Result:

1. The consumer's pinned OID no longer exists → health check `sink_configuration` → `error_slug: no_tables_in_publication` (status `notice`), message "No tables in publication...".
2. The swapped-in same-named table gets a new OID and is **NOT** re-added to the publication (Sequin publications are explicit per-table, `pg_publication.puballtables = f`), so even the live table isn't replicated.

This is the sibling of `cleanup-stale-webhooks` — that one *deletes* dead webhooks; this one *repairs* live ones whose source table was swapped.

## Important / Critical

- **Confirm with the user before any write** (`ALTER PUBLICATION`, `ALTER TABLE`, `UPDATE sink_consumers`). Always run the detection + dry-run verification first and show the plan.
- **`sequin` DB user CANNOT `ALTER PUBLICATION`** — the publication is owned by `root`/`admin`. You MUST connect as the owner via the cluster's **RDS proxy** (Step 4).
- **Raw DB edits do NOT take runtime effect on their own.** Running Sequin consumers cache config in memory; the table cache refreshes on a schedule. After remediation you must trigger a reload (Step 7) or the fix is inert.
- **Map authoritatively** via control-plane `SubgraphDeployment.sgd_id` → physical schema `sgd<sgd_id>`. Source DBs have many same-named tables (e.g. hundreds of `pool`/`withdrawal_request` across deployments); adding the wrong one replicates another customer's data. Never guess the schema.
- Always tunnel via the SSH alias **`bastion-prod-usw2`**, never the raw bastion IP.
- macOS ships **bash 3.2 — no `declare -A`** (associative arrays). Use `case` statements for port/cred lookups in loops, or they silently hit the wrong server.
- The sandbox blocks `shred`, `rm -rf`, and `mv` from `$HOME`/system paths. Clean up temp secret files with plain `rm -f`.
- If AWS calls fail with "Token has expired", have the user run `aws --profile prod sso login`.

## Step 1: Establish connections (tunnels via bastion-prod-usw2)

```bash
# Sequin DB
aws --profile prod --region us-west-2 secretsmanager get-secret-value \
  --secret-id "sequin/rds-credentials" --query SecretString --output text   # {"username","password"}
ssh -f -N -L 15433:sequin-database.cn9cukuadcb4.us-west-2.rds.amazonaws.com:5432 bastion-prod-usw2 -o StrictHostKeyChecking=no
# psql: PGPASSWORD=<pw> psql -h localhost -p 15433 -U postgres -d sequin

# Control plane (goldsky-api)
doppler secrets get DATABASE_URL --project goldsky-api --config prod --plain   # postgres:<pw>@control-plane-proxy...
ssh -f -N -L 15434:control-plane.cluster-cn9cukuadcb4.us-west-2.rds.amazonaws.com:5432 bastion-prod-usw2 -o StrictHostKeyChecking=no
# psql: PGPASSWORD=<pw> psql -h localhost -p 15434 -U postgres -d goldsky
```

Control-plane column names are snake_case (`project_id`, `subgraph_deployment_id`), and `"Webhook"`/`"SubgraphDeployment"` are quoted CamelCase tables in schema `goldsky_api`.

## Step 2: Detect affected consumers (Sequin DB)

The precise symptom is the `sink_configuration` health check with `error_slug = no_tables_in_publication`:

```sql
SELECT db.name AS source_db, rs.publication_name, sc.name AS consumer,
       (sc.source->'include_table_oids')->>0 AS dead_oid,
       (chk->>'last_healthy_at')::timestamptz AS last_healthy_at
FROM sequin_config.health_snapshots hs
JOIN sequin_config.sink_consumers sc ON sc.id::text = hs.entity_id
JOIN sequin_config.postgres_replication_slots rs ON rs.id = sc.replication_slot_id
JOIN sequin_config.postgres_databases db ON db.id = rs.postgres_database_id,
  jsonb_array_elements(hs.health_json->'checks') AS chk
WHERE hs.entity_kind='sink_consumer'
  AND chk->>'slug'='sink_configuration'
  AND chk->>'error_slug'='no_tables_in_publication'
ORDER BY db.name, sc.name;
```

For a single webhook the user names, filter `sc.name = '<webhook_id>'` (it matches control-plane `Webhook.id`). Clustered `last_healthy_at` timestamps across many consumers = one pruning sweep.

## Step 3: Map each consumer to its current table (authoritative)

Join the affected consumer names (= `Webhook.id`) through the control plane. `SubgraphDeployment.sgd_id` is the physical schema number; `shard` is the source DB:

```sql
-- control plane (port 15434)
SELECT w.id AS consumer, w.entity, sd.shard,
       'sgd'||sd.sgd_id AS schema, sd.status,
       'sgd'||sd.sgd_id||'.'||w.entity AS target_table
FROM goldsky_api."Webhook" w
JOIN goldsky_api."SubgraphDeployment" sd ON sd.id = w.subgraph_deployment_id
WHERE w.id IN ('<consumer1>','<consumer2>', ...)
ORDER BY sd.shard, sd.sgd_id, w.entity;
```

- `shard` → source DB name `<shard>_client__goldskyraw` and the matching RDS proxy (Step 4).
- Consumers with **no control-plane row** are orphans — do NOT remediate; they belong to `cleanup-stale-webhooks`.

## Step 4: Get RDS proxy root creds and connect as the publication owner

`sequin` can't ALTER the publication. Each graph-node cluster has an RDS proxy fronting it, authed with the cluster root/admin secret:

```bash
aws --profile prod --region us-west-2 rds describe-db-proxies \
  --query "DBProxies[?starts_with(DBProxyName,'proxy-graph-node')].{Name:DBProxyName,Endpoint:Endpoint,Auth:Auth[].SecretArn}"
```

For each needed shard: fetch the proxy's auth secret (use the **full ARN** from the output — the short name without the timestamp/suffix won't resolve), then tunnel to the proxy endpoint and connect with `sslmode=require`:

```bash
# username/password from the secret
aws --profile prod --region us-west-2 secretsmanager get-secret-value --secret-id "<full-arn>" \
  --query SecretString --output text   # {"username":"root"|"admin","password":...}
ssh -f -N -L <port>:proxy-graph-node-<shard>-2az.proxy-cn9cukuadcb4.us-west-2.rds.amazonaws.com:5432 \
  bastion-prod-usw2 -o StrictHostKeyChecking=no
PGPASSWORD=<pw> psql "host=localhost port=<port> user=<root|admin> dbname=client__goldskyraw sslmode=require"
```

`primary` shard uses `prod/graph-node/admin` (owner = `admin`); the other shards use their `rds-db-credentials/cluster-.../root/...` secret (owner = `root`). Verify owner/ALTER capability:

```sql
SELECT pubowner::regrole, puballtables FROM pg_publication WHERE pubname='sequin_pub_client__goldskyraw';
SELECT pg_has_role(current_user,(SELECT pubowner FROM pg_publication WHERE pubname='sequin_pub_client__goldskyraw'),'USAGE');
```

## Step 5: Dry-run verification (per target, on each source DB)

Confirm each `schema.entity` target before writing — it must exist, not already be published, and ideally have rows:

```sql
SELECT
  EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
         WHERE n.nspname='<schema>' AND c.relname='<entity>' AND c.relkind='r') AS exists,
  EXISTS(SELECT 1 FROM pg_publication_tables
         WHERE pubname='sequin_pub_client__goldskyraw' AND schemaname='<schema>' AND tablename='<entity>') AS in_pub,
  (SELECT CASE c.relreplident WHEN 'd' THEN 'default(pk)' WHEN 'f' THEN 'full' ELSE c.relreplident::text END
   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='<schema>' AND c.relname='<entity>') AS replica_ident,
  (SELECT c.reltuples::bigint FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='<schema>' AND c.relname='<entity>') AS approx_rows;
```

Also confirm the dead OID is actually gone: `SELECT <dead_oid> IN (SELECT oid FROM pg_class);` → expect `f`. Present the full plan to the user and get explicit approval.

## Step 6: Remediate (as publication owner via proxy)

For each verified target (idempotent — skip if `in_pub` already true):

```sql
ALTER PUBLICATION sequin_pub_client__goldskyraw ADD TABLE <schema>.<entity>;
ALTER TABLE <schema>.<entity> REPLICA IDENTITY FULL;
SELECT c.oid AS new_oid FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='<schema>' AND c.relname='<entity>';   -- capture new OID
```

Then update Sequin's stored OIDs (Sequin DB, port 15433, as `postgres`). Map each consumer → its target's new OID and run one batched update:

```sql
UPDATE sequin_config.sink_consumers sc
SET source = jsonb_set(sc.source, '{include_table_oids}', to_jsonb(ARRAY[v.newoid])),
    updated_at = now()
FROM (VALUES ('<consumer>', <new_oid>::bigint), ...) AS v(name, newoid)
WHERE sc.name = v.name
  AND (sc.source->'include_table_oids') IS DISTINCT FROM to_jsonb(ARRAY[v.newoid]);
```

Verify every consumer now holds its expected new OID (0 mismatches).

## Step 7: Activate the fix (REQUIRED — raw edits are inert until reload)

Cadence, from the Sequin code:
- **Table metadata cache** (`postgres_databases.tables`): refreshed by cron **every 6h** (`0 */6 * * *`, EnqueueDatabaseUpdateWorker) AND **immediately** when a WAL relation message shows a schema-hash change (`relation.ex` enqueues with `unique_period: 0`).
- **Consumer config in memory** (the new `include_table_oids`): **NOT periodic.** It only reloads when the slot's replication tree restarts, triggered by an **app-driven** consumer create/update/delete (`ConsumerLifecycleEventWorker` → `RuntimeSupervisor.restart_replication`) or a Sequin deploy/restart. A raw SQL `UPDATE` does NOT fire this.

So after Step 6, the running consumers still hold the dead OID. To activate, do one of:
1. Bump each affected consumer through Sequin's normal update path (re-triggers `restart_replication` and re-runs the sink-config check, clearing the notice), or
2. Restart Sequin / the affected slots' replication trees.

Confirm with the user which they want; do not restart prod Sequin unprompted. After activation, re-run Step 2 — the `no_tables_in_publication` notices should clear.

## Step 8: Clean up

`rm -f` any temp credential/password files. Leave a short summary: tables added, replica identities set, consumer OIDs updated, and the activation step taken (or still pending).

## Common Issues

### `ALTER PUBLICATION ... permission denied`
**Cause:** Connected as `sequin`, which doesn't own the publication.
**Solution:** Connect as `root`/`admin` via the cluster's RDS proxy (Step 4).

### Secret "can't find the specified secret"
**Cause:** Used the short secret name and dropped the timestamp/suffix.
**Solution:** Use the full ARN from `describe-db-proxies` Auth output.

### Loop hits the wrong DB / EXISTS=f for tables you know exist
**Cause:** `declare -A` on macOS bash 3.2 fails silently → empty port → psql defaults to 5432.
**Solution:** Use a `case` function for port/cred lookup; verify with `SELECT inet_server_addr()` per port.

### Target table doesn't exist on the source DB
**Cause:** The deployment was fully removed (not just pruned), or the wrong schema was derived.
**Solution:** Re-confirm `SubgraphDeployment.sgd_id` and `shard`. If the schema is gone entirely, this is a deleted subgraph, not a prune-swap — route to `cleanup-stale-webhooks`.

### Health still shows `notice` after remediation
**Cause:** Sequin hasn't reloaded (Step 7). Raw DB edits don't restart consumers.
**Solution:** Trigger an app-level consumer update or restart; the table cache also needs ≤6h or a change flowing through the table.

### No AWS master secret for a non-primary graph-node cluster
**Cause:** Only `graph-node-database-cluster` (primary) has `prod/graph-node/{root,admin}`.
**Solution:** Use the per-cluster RDS proxy secret (Step 4). For read-only source inspection without the proxy, decrypt Sequin's stored `sequin` password (Cloak AES-256-GCM, AAD `AES256GCM`, key = `VAULT_KEY` from `sequin/config`).
