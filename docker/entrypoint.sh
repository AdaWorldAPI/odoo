#!/usr/bin/env bash
#
# Entrypoint for the Railway-flavoured Odoo image.
#
# Responsibilities:
#   1. Translate Railway-style env vars into Odoo CLI flags / config values.
#      - $DATABASE_URL  : full postgres://user:pass@host:port/db connection string
#      - $PORT          : public HTTP port assigned by Railway
#   2. Honour the discrete PG* / ODOO_* overrides if a user prefers them.
#   3. Wait for Postgres to be reachable before exec'ing Odoo (Railway plugins
#      usually come up before the app, but this avoids race conditions on cold
#      starts).
#   4. On first boot, optionally create + seed the database (Railway
#      "Set up DB" + "Populate test data" — driven by service variables).
#   5. exec into odoo-bin so it gets PID 1 and signals propagate cleanly.

set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# Truthy test for the Railway boolean "checkmark" variables (1/true/yes/on).
is_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on|y) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Parse $DATABASE_URL (postgresql://user:password@host:port/database?params)
# into PG* variables that Odoo understands.
# ---------------------------------------------------------------------------
if [[ -n "${DATABASE_URL:-}" ]]; then
    python_parse=$(python3 - <<'PY'
import os
import sys
from urllib.parse import urlparse, unquote

url = urlparse(os.environ["DATABASE_URL"])
if url.scheme not in ("postgres", "postgresql"):
    sys.stderr.write(f"DATABASE_URL scheme must be postgres[ql], got {url.scheme!r}\n")
    sys.exit(1)

def export(name, value):
    if value is None or value == "":
        return
    # single-quote the value for safe `eval` in bash
    escaped = str(value).replace("'", "'\\''")
    print(f"export {name}='{escaped}'")

export("PGHOST", url.hostname)
export("PGPORT", url.port or 5432)
export("PGUSER", unquote(url.username) if url.username else None)
export("PGPASSWORD", unquote(url.password) if url.password else None)
export("PGDATABASE", url.path.lstrip("/") or None)
PY
)
    eval "$python_parse"
fi

: "${PGHOST:=${HOST:-localhost}}"
: "${PGPORT:=5432}"
: "${PGUSER:=odoo}"
: "${PGPASSWORD:=}"
: "${PGDATABASE:=${POSTGRES_DB:-postgres}}"

# Odoo reads these:
export DB_HOST="$PGHOST"
export DB_PORT="$PGPORT"
export DB_USER="$PGUSER"
export DB_PASSWORD="$PGPASSWORD"

# ---------------------------------------------------------------------------
# Wait for Postgres. Bounded so Railway's healthcheck eventually flags us as
# down rather than spinning forever.
# ---------------------------------------------------------------------------
wait_for_postgres() {
    local attempts="${POSTGRES_WAIT_ATTEMPTS:-30}"
    local delay="${POSTGRES_WAIT_DELAY:-2}"
    local i=0
    log "Waiting for Postgres at ${PGHOST}:${PGPORT} (user=${PGUSER}, db=${PGDATABASE})"
    while (( i < attempts )); do
        if PGPASSWORD="$PGPASSWORD" pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" >/dev/null 2>&1; then
            log "Postgres is reachable."
            return 0
        fi
        i=$((i + 1))
        sleep "$delay"
    done
    log "Postgres did not become reachable after $((attempts * delay))s; starting Odoo anyway."
    return 1
}

# ---------------------------------------------------------------------------
# First-boot database setup — the Railway "Set up DB" + "Populate test data"
# flow, driven entirely by service variables (a headless container has no
# interactive prompt, so the variables ARE the checkboxes).
#
# On a fresh Postgres the target DB has no Odoo schema, and the DB-manager UI
# is disabled (list_db=False), so /web/health answers 200 but nothing is
# usable until the schema is installed. These helpers detect that state from
# the PG connection already parsed out of $DATABASE_URL and, when the operator
# opts in, run a one-shot `-i <modules> --stop-after-init` BEFORE the server
# starts — optionally seeding Odoo's demo/test data.
#
#   ODOO_DB_SETUP=1            → "Set up DB": auto-init an empty DB on first boot
#   ODOO_POPULATE_TEST_DATA=1  → "Populate test data": load Odoo demo data
#   ODOO_SETUP_MODULES=a,b,c   → modules to install (default: base)
#   ODOO_ADMIN_PASSWORD=...    → set the admin user's password after init
#
# Idempotent: once the schema exists, setup is skipped on every later boot, so
# both variables can safely stay set. Detection = presence of Odoo's signature
# table `ir_module_module` in the target DB.
# ---------------------------------------------------------------------------

# Target database for first-boot setup. Defaults to the DB in $DATABASE_URL
# (the Railway plugin's own database), so Odoo initializes INTO the existing
# DB and needs no CREATEDB privilege. Set ODOO_DATABASE / ODOO_DB_NAME to a
# different name only if the PG role has CREATEDB.
SETUP_DB="${ODOO_DATABASE:-${ODOO_DB_NAME:-$PGDATABASE}}"

# Scalar psql query that never aborts the script on failure (set -e / pipefail
# safe). $1 = database to connect to, $2 = SQL returning one value.
psql_q() {
    PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
        -d "$1" -tAqc "$2" 2>/dev/null | tr -d '[:space:]' || true
}

db_exists() {
    # pg_database is a shared catalog — read it from the always-present URL DB.
    [[ "$(psql_q "$PGDATABASE" "SELECT 1 FROM pg_database WHERE datname='${SETUP_DB}'")" == "1" ]]
}

db_is_initialized() {
    db_exists || return 1
    # to_regclass returns NULL (empty) when the table is absent.
    [[ -n "$(psql_q "$SETUP_DB" "SELECT to_regclass('public.ir_module_module')")" ]]
}

set_admin_password() {
    log "Setting admin user password from ODOO_ADMIN_PASSWORD."
    # env.ref('base.user_admin').password auto-hashes via the field setter.
    /opt/odoo/odoo-bin shell \
        --config "${ODOO_RC:-/etc/odoo/odoo.conf}" \
        -d "$SETUP_DB" --db_host "$PGHOST" --db_port "$PGPORT" \
        --db_user "$PGUSER" --db_password "$PGPASSWORD" --no-http <<'PYEOF'
import os
admin = env.ref('base.user_admin')
admin.password = os.environ['ODOO_ADMIN_PASSWORD']
env.cr.commit()
PYEOF
}

maybe_setup_database() {
    if db_is_initialized; then
        log "Database '${SETUP_DB}' already initialized — skipping first-boot setup."
        return 0
    fi
    if ! is_truthy "${ODOO_DB_SETUP:-}"; then
        log "Database '${SETUP_DB}' is NOT initialized and ODOO_DB_SETUP is unset."
        log "  -> Set ODOO_DB_SETUP=1 (and optionally ODOO_POPULATE_TEST_DATA=1),"
        log "     then redeploy, to create the schema automatically on first boot."
        return 0
    fi

    local modules="${ODOO_SETUP_MODULES:-${ODOO_INIT_MODULES:-base}}"
    # Odoo 19: --without-demo stores into with_demo (inverted). False => demo ON.
    local demo=("--without-demo=True")   # clean DB (production default)
    if is_truthy "${ODOO_POPULATE_TEST_DATA:-}"; then
        demo=("--without-demo=False")     # load Odoo demo / test data
        log "First boot: initializing '${SETUP_DB}' with modules [${modules}] + demo/test data."
    else
        log "First boot: initializing '${SETUP_DB}' with modules [${modules}] (no demo data)."
    fi

    /opt/odoo/odoo-bin \
        --config "${ODOO_RC:-/etc/odoo/odoo.conf}" \
        -d "$SETUP_DB" \
        --db_host "$PGHOST" --db_port "$PGPORT" \
        --db_user "$PGUSER" --db_password "$PGPASSWORD" \
        -i "$modules" "${demo[@]}" --stop-after-init

    if [[ -n "${ODOO_ADMIN_PASSWORD:-}" ]]; then
        set_admin_password
    fi
    log "First-boot setup complete for '${SETUP_DB}'."
}

# ---------------------------------------------------------------------------
# HTTP port. Railway injects $PORT; Odoo's flag is --http-port.
# ---------------------------------------------------------------------------
HTTP_PORT="${PORT:-${ODOO_HTTP_PORT:-8069}}"

# ---------------------------------------------------------------------------
# Build the argv we'll exec. Anything the user passes via CMD/`docker run` is
# appended verbatim so they can override or add modules at boot.
# ---------------------------------------------------------------------------
args=(
    "--config" "${ODOO_RC:-/etc/odoo/odoo.conf}"
    "--http-port" "$HTTP_PORT"
    "--db_host"   "$PGHOST"
    "--db_port"   "$PGPORT"
    "--db_user"   "$PGUSER"
    "--db_password" "$PGPASSWORD"
)

# Bind to all interfaces so Railway's proxy can reach us.
args+=("--http-interface" "0.0.0.0")

# If the operator pinned a single database, pass it through. This is the
# typical Railway setup since each environment gets one Postgres plugin.
if [[ -n "${ODOO_DATABASE:-${PGDATABASE:-}}" && "${PGDATABASE}" != "postgres" ]]; then
    args+=("--database" "${ODOO_DATABASE:-$PGDATABASE}")
fi

# Comma-separated module list to install on first boot, if requested.
if [[ -n "${ODOO_INIT_MODULES:-}" ]]; then
    args+=("--init" "$ODOO_INIT_MODULES" "--stop-after-init")
fi

# Comma-separated module list to update on boot, if requested.
if [[ -n "${ODOO_UPDATE_MODULES:-}" ]]; then
    args+=("--update" "$ODOO_UPDATE_MODULES")
fi

# Extra addons path: /mnt/extra-addons by default (Volume mount point).
if [[ -d "/mnt/extra-addons" ]] && [[ -n "$(ls -A /mnt/extra-addons 2>/dev/null || true)" ]]; then
    args+=("--addons-path" "/opt/odoo/addons,/mnt/extra-addons")
fi

wait_for_postgres || true

case "${1:-odoo}" in
    odoo|odoo-bin)
        shift || true
        maybe_setup_database
        log "exec odoo-bin ${args[*]} $*"
        exec /opt/odoo/odoo-bin "${args[@]}" "$@"
        ;;
    shell|scaffold|db|cloc|deploy|populate|server|start|upgrade|tsconfig|gen_translations)
        # Forward Odoo sub-commands verbatim with the same DB plumbing.
        subcmd="$1"; shift
        log "exec odoo-bin $subcmd ${args[*]} $*"
        exec /opt/odoo/odoo-bin "$subcmd" "${args[@]}" "$@"
        ;;
    -*)
        log "exec odoo-bin ${args[*]} $*"
        exec /opt/odoo/odoo-bin "${args[@]}" "$@"
        ;;
    *)
        # Arbitrary command — useful for `docker run ... bash`.
        log "exec $*"
        exec "$@"
        ;;
esac
