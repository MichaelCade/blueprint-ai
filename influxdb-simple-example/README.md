# InfluxDB with Kasten — stop, snapshot, start

Back up a **single-replica InfluxDB OSS** `Deployment` with a clean on-disk state. InfluxDB 1.x
has no command that pauses writes, so the blueprint stops it (scale to 0) just before Kasten
snapshots its PVC and starts it again afterwards: about 20 seconds of downtime, and a restore
that needs no script. A watchdog Job starts InfluxDB again if a cancelled backup does not.

The concept deck: [influxdb-simple.pptx](influxdb-simple.pptx).

## Pick the folder for your InfluxDB version

| InfluxDB | Folder | Kubernetes | Kasten | Tool image | Status |
|---|---|---|---|---|---|
| 1.11.8 OSS | [1.11/](1.11/) | 1.34.1 | 9.0.8 | `kasten-tools:9.0.8` | Validated end to end (Steps 1–6), restore from export |

A folder is a **record of what was validated** on that version. It is not changed when work moves
to another version. To add a version, copy the nearest folder, adapt it, and re-run Steps 2–5 of
[AGENTS.md](../AGENTS.md).

InfluxDB 2.x and 3.x store data differently from 1.x (2.x: an embedded key-value store for
metadata beside the TSM engine; 3.x: Parquet files, often on object storage). They have not been
tested with this blueprint. A version folder for them needs its own Steps 2–5.

## When not to use this blueprint

| If you need | Use instead |
|---|---|
| No write downtime at all | A blueprint based on `influxd backup -portable` (pattern 3), which backs up online |
| Restore of a single database | Same: `influxd restore -portable -db` restores one database |
| More than one replica | InfluxDB OSS cannot run more than one replica on one data volume; this blueprint assumes one |
