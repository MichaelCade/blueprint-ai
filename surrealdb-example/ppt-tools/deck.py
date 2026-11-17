#!/usr/bin/env python3
"""Concept deck for surrealdb-example. Content only — the slide machinery lives in
the shared toolkit at ../../ppt-tools/veeam_deck.py.

    python3 ppt-tools/build.py surrealdb-example
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'ppt-tools'))
from veeam_deck import Deck  # noqa: E402

d = Deck('surrealdb', 'surrealdb-example')

d.title("SURREALDB WITH KASTEN",
        "A consistent logical dump on a keeper PVC, with no write pause")

d.agenda([
    "Why a disk snapshot alone is not enough",
    "The pattern, and the patterns ruled out",
    "Architecture and blueprint actions",
    "Restore, and what the dump does not hold",
])

d.hero(
    "NO WAY TO PAUSE WRITES,", "SO SNAPSHOT A DUMP",
    body="SurrealDB has no command that pauses writes or flushes a consistent state to disk.\n"
         "A CSI snapshot of its data PVC is only crash-consistent: it has to recover like "
         "after a power cut.",
    pills=["No write pause", "Single node, SurrealKV", "Helm chart, no operator"],
    icon='database', polarity='neg')

d.cards(
    "Three facts decide the pattern",
    "Each one comes from the SurrealDB source or was checked on a cluster",
    [
        ('close_circle', "NO QUIESCE COMMAND", [
            "There is no equivalent of a global read lock, so pattern 2 (quiesce and "
            "snapshot) gives a crash-consistent copy only.",
        ]),
        ('checkbox_multiple', "EXPORT IS ONE TRANSACTION", [
            "surreal export reads a whole database inside one read transaction. Under "
            "about 50 paired writes per second, five exports in a row all came out "
            "consistent.",
        ]),
        ('lock', "NO SHELL IN THE SERVER", [
            "The production image is distroless, so nothing can run sync inside the "
            "SurrealDB pod. The -dev image of the same version has a shell and the "
            "same CLI.",
        ]),
    ])

d.table_slide(
    "Pattern 4 — and the patterns ruled out",
    "Ranked order from AGENTS.md; the first one that is technically possible wins",
    ["Pattern", "Why not"],
    [
        ("1. Fence a replica", "A single SurrealDB node has no replica."),
        ("2. Quiesce", "No command to pause writes: crash-consistent only."),
        ("3. Dump to a PVC on the SurrealDB pod",
         "No shell in the server image, so no sync before the snapshot."),
        ("4. Dump on a keeper PVC", "Chosen. The keeper has the CLI and a shell."),
        ("5. MinIO keeper", "SurrealDB has no native backup to S3."),
        ("7-9. Temporary PVC", "Not needed: a permanent PVC works."),
    ],
    col_widths=[4.2, 8.1])

d.flow(
    "Architecture",
    "The keeper is the only writer during backup; Kasten snapshots both PVCs",
    [
        ('database_storage', "SURREALDB 3.3.5",
         "Production image, no shell.\nData PVC: crash-consistent\ncopy in the restore point"),
        ('server_hardware', "KEEPER, v3.3.5-dev",
         "surreal CLI and a shell.\nExports over HTTP to\nits own permanent PVC"),
        ('folder', "ONE FILE PER DATABASE",
         "/backup/surrealdb/<ns>/<db>.surql\nplus a SHA-256 MANIFEST,\nthen sync"),
        ('shield_check', "KASTEN SNAPSHOT + EXPORT",
         "Snapshots both PVCs,\nexports the restore point\nto object storage"),
    ],
    note=("Why the binding is on the keeper, not on SurrealDB.",
          "The keeper is the pod the blueprint execs into. A BlueprintBinding matches every "
          "Deployment labelled blueprint-ai/surrealdb-keeper, so a second SurrealDB instance "
          "only needs its own keeper. Nothing in kasten-io changes."))

d.table_slide(
    "Blueprint actions",
    "Two actions. There is no backupPosthook, because nothing was paused",
    ["Action", "What it does"],
    [
        ("backupPrehook",
         "KubeExec into the keeper. Export every namespace and database to a staging "
         "directory with a checksum MANIFEST, swap it in, run sync last, then re-check "
         "every file. An empty export or a bad checksum fails the backup."),
        ("restorePosthook",
         "After Kasten restores the PVCs: check every file before touching anything, wait "
         "for SurrealDB, then per database REMOVE DATABASE, DEFINE DATABASE IF NOT "
         "EXISTS, surreal import."),
    ],
    col_widths=[2.6, 9.7])

d.hero(
    "SYNC IS THE", "LAST THING THE PREHOOK DOES",
    body="A CSI snapshot copies the block device, not the page cache.\n"
         "Without sync, a dump can reach the restore point with the right name and zero "
         "bytes, and nobody notices until the restore.",
    pills=["Last step", "Checked against the MANIFEST", "Verified in Step 3"],
    icon='shield')

d.two_dark(
    "WHAT A RESTORE DOES", "Two copies come back. Only one is authoritative",
    [
        ("01", "THE DATA PVC", "Crash-consistent", "Restored as it was. SurrealKV recovers from it and "
         "starts. It still matters for what the dump does not hold: root and namespace "
         "users and access methods."),
        ("02", "THE KEEPER DUMP", "Authoritative", "Wins for every database in it. The restorePosthook "
         "removes each database and imports its dump, so records written after the "
         "backup do not survive."),
    ])

d.cards(
    "What the dump does not protect",
    "Know these before you rely on it",
    [
        ('error', "ROOT AND NAMESPACE USERS", [
            "A database export holds database-level users only. Root users come back from "
            "the data PVC, or from the Secret on an empty instance.",
        ]),
        ('time', "CROSS-DATABASE CONSISTENCY", [
            "Each database is exported in its own transaction. Two databases are each "
            "consistent, but not at the same instant.",
        ]),
        ('history', "INCREMENTALITY", [
            "Every backup is a full dump. Measured: 1% of records changed on consecutive "
            "keys re-exported 6% of the data; the same 1% scattered re-exported 51%.",
        ]),
    ], style='negative')

d.ending("A CONSISTENT COPY WITHOUT PAUSING WRITES",
         "One read transaction per database, written by a keeper, flushed, then snapshotted.\n"
         "github.com/kastenhq/blueprint-ai — surrealdb-example")

d.save()
