# Import rehearsal

The import scripts in `tools/import/` write files to Active Storage. `DRY_RUN=1` rolls back the database, and the
scripts now also delete every file uploaded during a run that does not commit. Rehearsals still run only in this
separate environment, with a synthetic test export, so a fault in either safeguard cannot reach the live storage
or database.

## Safeguards in the scripts

- `IMPORT_TARGET` is required: `rehearsal` or `live`.
- `DRY_RUN=1` is refused unless `IMPORT_TARGET=rehearsal`.
- `IMPORT_TARGET=rehearsal` is refused unless storage is a Disk service whose root contains the file
  `STEVENSED_REHEARSAL_STORAGE` and the database is not the live `docuseal` database.
- `IMPORT_TARGET=live` is refused if the storage carries the rehearsal marker.
- Files uploaded during a run that rolls back or fails are deleted from storage.

## Procedure (on the Agreements VM)

```bash
export REHEARSAL_DIR=/opt/agreements-rehearsal IMAGE_TAG=<commit>
sudo install -d "$REHEARSAL_DIR/data/docuseal/attachments"
sudo touch "$REHEARSAL_DIR/data/docuseal/attachments/STEVENSED_REHEARSAL_STORAGE"
sudo chown -R 2000:2000 "$REHEARSAL_DIR/data"
export SECRET_KEY_BASE=$(openssl rand -hex 64)   # rehearsal only; not stored
sudo -E docker compose -f tools/import/rehearsal/docker-compose.yml up -d
sudo docker cp tools agreements-rehearsal-app:/app/   # the image does not include tools/
sudo docker exec -w /app agreements-rehearsal-app bin/rails db:prepare
```

Create an account and an admin user (random password, not displayed), build the test export, then rehearse:

```bash
r() { sudo docker exec -w /app -e IMPORT_ROOT=/data/rehearsal-export "$@"; }   # -e options before the container
C=agreements-rehearsal-app
r $C bin/rails runner tools/import/build_test_export.rb
r -e IMPORT_TARGET=rehearsal -e DRY_RUN=1 $C bin/rails runner tools/import/docuseal_cloud_import.rb
r -e IMPORT_TARGET=rehearsal $C bin/rails runner tools/import/docuseal_cloud_import.rb
r -e IMPORT_TARGET=rehearsal $C bin/rails runner tools/import/docuseal_cloud_signatures.rb
```

Check after each step that the number of files in storage equals the number of blobs (no orphan files), and that a
second run reports every record as existing. Remove the environment afterwards:

```bash
sudo -E docker compose -f tools/import/rehearsal/docker-compose.yml down -v
sudo rm -rf /opt/agreements-rehearsal
```

## Rehearsal of 2026-11-26

Image `ec7da6d` with these scripts copied in; synthetic export (2 templates, 2 submissions, 2 signatures).
Refused as intended: no `IMPORT_TARGET`; `IMPORT_TARGET=live` with `DRY_RUN=1`; `IMPORT_TARGET=live` on rehearsal
storage; and, in the live container, every dry-run combination (live counts unchanged). Dry run: 10 files uploaded
and removed, storage back to 0. Committed run: 10 files, 10 blobs, 0 orphans; second run reported all 4 records as
existing. Signatures: dry run removed its 2 files; committed run added 2; second run reported both as existing.
Environment removed afterwards.
