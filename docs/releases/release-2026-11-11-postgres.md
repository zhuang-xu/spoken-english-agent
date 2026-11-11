# PostgreSQL cutover — November 11, 2026

Azure Functions deployment `fe4b5e64-85e7-46c3-8305-f5d8da8613dc` became active at
16:02:28 Asia/Shanghai. The app uses PostgreSQL 16 on
`spoken-agents-pg-4fa2534c`, database `spokenagents`. The Function App stays in
East US. The B1ms database is in Central US because the subscription could not
provision PostgreSQL in East US or East US 2.

The database has public access disabled. The Function App reached it through
Private Link and verified its hostname with TLS. The initial attempt failed with
the system trust setting. The connection succeeded with the explicit CA bundle
packaged with the Function App. The runtime role has scoped data permissions and
one pooled connection per worker. The temporary migration credentials and worker
were removed.

## Migration verification

- The maintenance window paused learner and timer writes. The importer checked
  row counts and content digests before committing the PostgreSQL copy.
- The import included 3 account identities, 70 sessions, 23 learner turns,
  29 agent transcript parts, 11 Speech assessments, and 7 evaluation records.
- All 23 legacy recordings were copied to the private `spoken-learner-recordings`
  container. The worker verified the byte count and SHA-256 of every object and
  confirmed that PostgreSQL had zero inline recordings.
- The Function App checked private DNS, queried the schema as the application
  role, and rolled back a synthetic write.
- The frozen SQLite Blob remains the pre-cutover backup. Run future orphan sweeps
  against the active PostgreSQL database. See the
  [hosted storage contract](../hosted-storage-api-contract.md).

## Release verification

All 265 tests passed on Python 3.11.6 against the staged release, including
concurrent PostgreSQL writes, evaluation claims, and the SQLite importer. The
39-file source ZIP has SHA-256
`27c9b6a3b7956bd5ed89ed2aadef0e9ffa64418835bcdcb2518f8f4386256f99`.
All source files matched the active Azure build byte for byte.

After learner writes reopened, Azure reported the Functions host `Running`.
Anonymous health, OpenAPI, account, session creation, and learner audio requests
returned `401`.

A signed-in hosted learner journey and a production load comparison remain open.
