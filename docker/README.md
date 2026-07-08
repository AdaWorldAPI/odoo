# Deploying Odoo on Railway

This directory contains the assets used by the top-level `Dockerfile` to build
an Odoo image that runs on [Railway](https://railway.com).

## Files

| Path                     | Purpose                                                          |
| ------------------------ | ---------------------------------------------------------------- |
| `../Dockerfile`          | Image definition (Ubuntu 24.04 + Odoo 19.0 + wkhtmltopdf 0.12.6) |
| `../railway.json`        | Railway build/deploy config (Dockerfile builder, healthcheck)    |
| `../.dockerignore`       | Keeps build context lean                                         |
| `entrypoint.sh`          | Translates Railway env vars into Odoo CLI flags                  |
| `odoo.conf`              | Baseline Odoo config (proxy_mode, no DB manager, etc.)           |

## One-time setup on Railway

1. Create a new project and add a **PostgreSQL** plugin. Railway will set
   `DATABASE_URL` on the Odoo service automatically once the plugin is linked.
2. Add this repository as a service. Railway detects `railway.json` and uses
   the Dockerfile builder.
3. Provision a **Volume** mounted at `/var/lib/odoo` so the filestore and
   sessions survive restarts. If you ship custom modules, mount a second
   volume at `/mnt/extra-addons`.
4. In the Odoo service **Variables**, set **`ODOO_DB_SETUP=1`** to have the
   first deploy create + initialize the database automatically. For a
   demo/staging box, also set **`ODOO_POPULATE_TEST_DATA=1`** to seed Odoo's
   test data. (Both are safe to leave on — they only act while the DB is
   empty.)
5. Deploy. The container binds to `$PORT` automatically, initializes the DB on
   the first boot, and serves once `/web/health` is green.

## Environment variables

The entrypoint reads the Railway Postgres URL (host, port, user, **password**,
db name) out of `DATABASE_URL` automatically — you never hand-wire `PG*`. The
first-boot behaviour is controlled by the two "checkbox" variables at the top
of the table (a headless container has no interactive prompt, so setting the
variable **is** ticking the box).

| Variable                  | Default      | Notes                                                                          |
| ------------------------- | ------------ | ------------------------------------------------------------------------------ |
| `ODOO_DB_SETUP`           | _(unset)_    | **"Set up DB"** — set to `1` to auto-create + initialize an empty DB on first boot. Idempotent: skipped once the schema exists. |
| `ODOO_POPULATE_TEST_DATA` | _(unset)_    | **"Populate test data"** — set to `1` to load Odoo's demo/test data during that first-boot init. Ignored if the DB is already initialized. |
| `DATABASE_URL`            | _(required)_ | Set by the Railway Postgres plugin. Parsed for host/port/user/password/db.     |
| `PORT`                    | `8069`       | Injected by Railway; the entrypoint forwards it to `--http-port`.              |
| `ODOO_DATABASE`           | from URL     | Target/pinned database name. Defaults to the DB in `DATABASE_URL` (so init needs no `CREATEDB`); set a different name only if the PG role has `CREATEDB`. |
| `ODOO_SETUP_MODULES`      | `base`       | Comma-separated modules to install during first-boot setup.                    |
| `ODOO_ADMIN_PASSWORD`     | _(unset)_    | Admin password, set right after init and **login-verified** (`res.users.authenticate`) before being reported. `generate` mints a random 20-char password, verifies it, and prints it ONCE in the deploy logs. Unset → loud `admin`/`admin` nudge in the logs. |
| `ODOO_ONBOARDING`         | `1`          | When the DB is uninitialized and `ODOO_DB_SETUP` is unset, serve a **graceful onboarding page** on `0.0.0.0:$PORT` (200 on every path incl. `/web/health`, so the healthcheck stays green) instead of booting Odoo into a broken no-schema state. Set `0` to boot Odoo anyway. |
| `ODOO_UPDATE_MODULES`     | _(unset)_    | Comma-separated; runs `-u` on boot (schema upgrades on an existing DB).        |
| `ODOO_INIT_MODULES`       | _(unset)_    | Legacy manual bootstrap (`--init … --stop-after-init` on every boot). Prefer `ODOO_DB_SETUP`. |
| `POSTGRES_WAIT_ATTEMPTS`  | `30`         | Times to retry `pg_isready` before giving up.                                  |
| `POSTGRES_WAIT_DELAY`     | `2` seconds  | Delay between retries.                                                          |

## Initial database bootstrap (automatic)

On first boot the entrypoint detects whether the target database has an Odoo
schema (presence of the `ir_module_module` table). If it does **not**:

- with **`ODOO_DB_SETUP=1`** it runs `-i base --stop-after-init` against the DB
  parsed from `DATABASE_URL`, then starts the server — one deploy, no shell
  step, nothing to unset afterwards;
- add **`ODOO_POPULATE_TEST_DATA=1`** to seed Odoo's demo/test data in the same
  pass (equivalent to `--without-demo=False`); omit it for a clean production DB;
- optionally set **`ODOO_ADMIN_PASSWORD`** to fix the admin login in the same
  step, and **`ODOO_SETUP_MODULES=base,sale,account,…`** to install more than
  `base`.

Because detection is idempotent, you can leave `ODOO_DB_SETUP=1` (and, for a
staging/demo environment, `ODOO_POPULATE_TEST_DATA=1`) set permanently — later
boots see the schema and skip straight to serving.

### Graceful onboarding (no DB / first visit)

If the DB is uninitialized and `ODOO_DB_SETUP` is **not** set, the container
serves an **onboarding page** on `0.0.0.0:$PORT` instead of a broken Odoo: it
answers 200 on every path (Railway's `/web/health` check stays green), shows
whether Postgres is reachable, and lists the exact three variables to set
(`ODOO_DB_SETUP=1`, optional `ODOO_POPULATE_TEST_DATA=1`,
`ODOO_ADMIN_PASSWORD=<pw>` or `=generate`) — then redeploy. `ODOO_ONBOARDING=0`
restores the old boot-anyway behaviour.

### Admin credentials (verified, no email confirmation)

The root admin needs no email confirmation. After first-boot init the
entrypoint sets the password from `ODOO_ADMIN_PASSWORD`, then **verifies the
login actually works** through `res.users.authenticate` (the same code path
as the login form) before reporting it. `ODOO_ADMIN_PASSWORD=generate` mints
a random password, verifies it, and prints it **once** in the deploy logs.
With no password set, the logs carry a loud `admin`/`admin` change-me nudge.
Postgres is this image's system of record — the lance-graph V3 storage lane
belongs to the separate odoo-rs deployment, not this container.

> Legacy path: `ODOO_INIT_MODULES` still works (manual `--stop-after-init` on
> every boot, then unset), but `ODOO_DB_SETUP` supersedes it for the hands-off
> flow. If **both** are set, `ODOO_DB_SETUP` wins and the legacy
> `--stop-after-init` injection is suppressed — so migrating from the legacy
> path by adding `ODOO_DB_SETUP=1` is safe and you can leave both variables in
> place. `ODOO_SETUP_MODULES` is independent of `ODOO_INIT_MODULES` (it does not
> inherit it).

## Local build / smoke test

```bash
docker build -t odoo-railway .
docker run --rm -p 8069:8069 \
    -e DATABASE_URL=postgresql://odoo:odoo@host.docker.internal:5432/odoo \
    odoo-railway
```
