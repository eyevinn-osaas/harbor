<h1 align="center">
  <a href="https://www.osaas.io">
    Eyevinn Open Source Cloud
  </a>
</h1>

<h4 align="center">
  Open Source as a Service
</h4>

<div align="center">
  <a href="https://www.osaas.io">osaas.io</a> |
  <a href="https://docs.osaas.io">Documentation</a> |
  <a href="https://github.com/EyevinnOSC">GitHub</a> |
  <a href="https://slack.osaas.io">Slack</a> |
  <a href="https://www.linkedin.com/company/eyevinn">LinkedIn</a>
</div>

# Harbor on Eyevinn Open Source Cloud

This fork of [Harbor](https://goharbor.io) (Apache-2.0, release v2.15.5) is packaged as a single
all-in-one container image for [Eyevinn Open Source Cloud](https://www.osaas.io) (OSC). It runs core,
jobservice, registryctl, the registry (goharbor/distribution v2.8.3-harbor.4), the portal and an nginx
reverse proxy in one container, and needs only PostgreSQL and Redis/Valkey as external services.
Image storage is either the persistent `/data` volume or an S3-compatible bucket.

Not included in this build: Trivy scanner, metrics exporter, log container, in-container HTTPS (OSC terminates TLS).

## Run it on OSC

1. Create a PostgreSQL database and a Valkey (or Redis) instance in OSC.
2. Create a Harbor instance and set `DATABASE_URL`, `REDIS_URL` and `HARBOR_ADMIN_PASSWORD`.
3. Open the instance URL and log in as `admin`. Use `docker login <hostname>` to push images.

### Configuration

| Variable | Required | Sensitive | Purpose |
|---|---|---|---|
| `DATABASE_URL` | yes | yes | `postgres://user:password@host:5432/dbname?sslmode=disable`. The database must exist. Name defaults to `registry`. Only `sslmode` is honoured from the query string. |
| `REDIS_URL` | yes | yes | `redis://[user]:password@host:6379` (or `rediss://`). Harbor uses db index 0, 1 and 2. |
| `HARBOR_ADMIN_PASSWORD` | recommended | yes | Initial admin password, only applied when Harbor initialises a new database. If unset a random one is generated and stored in `/data/secret/admin_password`. |
| `OSC_HOSTNAME` | set by OSC | no | Public hostname, becomes `https://$OSC_HOSTNAME`. |
| `HARBOR_EXTERNAL_URL` | no | no | Override the external URL (custom domain, local testing with `http://localhost:8080`). |
| `PORT` | set by OSC | no | Listen port, default 8080. |
| `LOG_LEVEL` | no | no | debug, info (default), warning, error, fatal. |
| `STORAGE_BACKEND` | no | no | `filesystem` (default, `/data/registry`) or `s3`. |
| `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` | with s3 | `S3_SECRET_KEY` and `S3_ACCESS_KEY` | S3 credentials and bucket. |
| `S3_ENDPOINT`, `S3_REGION`, `S3_SECURE`, `S3_SKIP_VERIFY`, `S3_FORCE_PATH_STYLE`, `S3_ROOT_DIRECTORY`, `S3_REDIRECT` | no | no | S3 details. Defaults: region `us-east-1`, secure `true`, path style `true`, redirect `false` (registry proxies blobs). |
| `HARBOR_SECRET_KEY` (16 chars), `HARBOR_CORE_SECRET`, `HARBOR_JOBSERVICE_SECRET`, `HARBOR_CSRF_KEY` (32 chars), `HARBOR_REGISTRY_HTTP_SECRET`, `HARBOR_TOKEN_PRIVATE_KEY` (PEM) | no | yes | Generated on first start and persisted under `/data/secret` unless provided. **Back up `/data/secret/secretkey` or set `HARBOR_SECRET_KEY`: it encrypts credentials stored in the database.** |
| `MAX_JOB_WORKERS` | no | no | Jobservice workers, default 10. |
| `HARBOR_ALLOW_PRIVATE_NETWORK_ACCESS` | no | no | Allow replication/webhooks to private networks, default `true`. |
| `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` | no | maybe | Outbound proxy for core and jobservice. |

Persistent data lives in `/data` (`registry`, `job_logs`, `secret`).

## About Eyevinn Open Source Cloud

Eyevinn Open Source Cloud makes it easy to run open source software as managed services. Anyone can
deploy open source projects with one click, without operating the infrastructure themselves.

Open source creators can make their projects available in the OSC service catalog and earn revenue
when others use them. To publish your own project, see the
[documentation](https://docs.osaas.io) or ask in our [Slack](https://slack.osaas.io).

## License

Harbor is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
