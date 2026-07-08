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
admin.login = 'admin'  # root admin login is deterministic; no email confirmation involved
admin.password = os.environ['ODOO_ADMIN_PASSWORD']
env.cr.commit()
PYEOF
}

# Double-check the admin credential actually AUTHENTICATES before presenting
# it (Odoo 19: `res.users.authenticate(credential, user_agent_env)` — the
# same code path the login form uses, so a pass here is a real login).
# Prints VERIFY_OK / VERIFY_FAIL; the function's exit status follows.
verify_admin_password() {
    local marker
    marker=$(/opt/odoo/odoo-bin shell \
        --config "${ODOO_RC:-/etc/odoo/odoo.conf}" \
        -d "$SETUP_DB" --db_host "$PGHOST" --db_port "$PGPORT" \
        --db_user "$PGUSER" --db_password "$PGPASSWORD" --no-http <<'PYEOF' 2>/dev/null | grep -oE 'VERIFY_(OK|FAIL)' | tail -1
import os
try:
    info = env['res.users'].authenticate(
        {'type': 'password', 'login': 'admin',
         'password': os.environ['ODOO_ADMIN_PASSWORD']},
        {'interactive': False},
    )
    uid = info.get('uid') if isinstance(info, dict) else info
    print('VERIFY_OK' if uid else 'VERIFY_FAIL')
except Exception:
    print('VERIFY_FAIL')
PYEOF
    )
    [[ "$marker" == "VERIFY_OK" ]]
}

# Post-init admin handling: generate-on-request, set, VERIFY, then present /
# nudge — loudly, in one banner block.
finalize_admin_credentials() {
    local generated=0
    if [[ "${ODOO_ADMIN_PASSWORD:-}" == "generate" ]]; then
        ODOO_ADMIN_PASSWORD="$(python3 -c 'import secrets,string;print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(20)))')"
        export ODOO_ADMIN_PASSWORD
        generated=1
    fi
    if [[ -n "${ODOO_ADMIN_PASSWORD:-}" ]]; then
        set_admin_password
        if verify_admin_password; then
            log "=================================================================="
            log " ADMIN LOGIN VERIFIED — user 'admin' authenticates successfully."
            if [[ "$generated" == "1" ]]; then
                log "   GENERATED PASSWORD (shown ONCE — store it now):"
                log "     login:    admin"
                log "     password: ${ODOO_ADMIN_PASSWORD}"
            fi
            log "   No email confirmation is required for the root admin."
            log "   NUDGE: change this password from Settings > Users after"
            log "   first login, and enable 2FA for production."
            log "=================================================================="
        else
            log "!! ================================================================"
            log "!! ADMIN PASSWORD VERIFICATION FAILED — the password was written"
            log "!! but 'admin' did NOT authenticate with it. Do not hand out this"
            log "!! credential. Re-run with a fresh ODOO_ADMIN_PASSWORD, or reset"
            log "!! via: odoo shell -> env.ref('base.user_admin').password = '...'"
            log "!! ================================================================"
        fi
    else
        log "=================================================================="
        log " ADMIN NUDGE: no ODOO_ADMIN_PASSWORD was set — the root admin is"
        log "   login: admin / password: admin  (Odoo's -i base default)."
        log "   CHANGE IT IMMEDIATELY, or redeploy with ODOO_ADMIN_PASSWORD=<pw>"
        log "   (or ODOO_ADMIN_PASSWORD=generate to mint + verify one for you)."
        log "=================================================================="
    fi
}

# Set to 1 when the DB is uninitialized and no setup was requested — the
# serve path then presents the graceful onboarding page instead of booting
# Odoo into a broken no-schema state. ODOO_ONBOARDING=0 restores the old
# start-anyway behaviour.
ONBOARDING_NEEDED=0

maybe_setup_database() {
    if db_is_initialized; then
        log "Database '${SETUP_DB}' already initialized — skipping first-boot setup."
        return 0
    fi
    if ! is_truthy "${ODOO_DB_SETUP:-}"; then
        log "Database '${SETUP_DB}' is NOT initialized and ODOO_DB_SETUP is unset."
        log "  -> Set ODOO_DB_SETUP=1 (and optionally ODOO_POPULATE_TEST_DATA=1),"
        log "     then redeploy, to create the schema automatically on first boot."
        # Onboarding only when NO setup path was requested at all: a legacy
        # deployment bootstrapping via ODOO_INIT_MODULES (codex P2 on #3) has
        # its --init/--stop-after-init argv built downstream and must run it,
        # not sit on the onboarding page.
        if [[ -z "${ODOO_INIT_MODULES:-}" ]]; then
            ONBOARDING_NEEDED=1
        fi
        return 0
    fi

    # Decoupled from the legacy ODOO_INIT_MODULES on purpose (codex P2): mixing
    # them would let the legacy --init/--stop-after-init serve-arg fire too.
    local modules="${ODOO_SETUP_MODULES:-base}"
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

    finalize_admin_credentials
    log "First-boot setup complete for '${SETUP_DB}'."
}

# Graceful onboarding: the DB is reachable but has no Odoo schema and setup
# was not requested. Booting Odoo here yields broken pages (list_db=False
# hides the DB manager), so instead serve a tiny static onboarding page on
# 0.0.0.0:$PORT that answers 200 on EVERY path (Railway's /web/health check
# stays green) and tells the operator exactly which variables to set. Runs
# as PID 1 via exec; the next redeploy with ODOO_DB_SETUP=1 boots Odoo.
serve_onboarding() {
    local db_state="unreachable"
    if PGPASSWORD="$PGPASSWORD" pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" >/dev/null 2>&1; then
        db_state="reachable, schema not initialized"
    fi
    log "Serving GRACEFUL ONBOARDING page on 0.0.0.0:${HTTP_PORT} (DB: ${db_state})."
    log "  (Set ODOO_ONBOARDING=0 to boot Odoo anyway.)"
    export ONBOARD_DB_STATE="$db_state" ONBOARD_HOST="$PGHOST" ONBOARD_DB="$SETUP_DB" HTTP_PORT
    exec python3 - <<'PYEOF'
import http.server
import os

STATE = os.environ.get("ONBOARD_DB_STATE", "unknown")
HOST = os.environ.get("ONBOARD_HOST", "?")
DB = os.environ.get("ONBOARD_DB", "?")
PAGE = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Odoo — first-run setup</title>
<style>body{{font-family:system-ui,sans-serif;max-width:44rem;margin:4rem auto;
padding:0 1rem;line-height:1.5}}code{{background:#eee;padding:.1em .35em;
border-radius:4px}}li{{margin:.4em 0}}.muted{{color:#666}}</style></head><body>
<h1>Odoo is deployed &mdash; one step left</h1>
<p>The container is healthy, but the database <code>{DB}</code> on
<code>{HOST}</code> is <b>{STATE}</b>, so Odoo has no schema to serve yet.</p>
<h2>Finish setup (Railway &rarr; Variables, then redeploy)</h2>
<ol>
<li><b>Set up the database:</b> <code>ODOO_DB_SETUP=1</code>
 <span class="muted">(idempotent &mdash; skipped once the schema exists)</span></li>
<li><b>Optional demo data</b> for a rich demo:
 <code>ODOO_POPULATE_TEST_DATA=1</code></li>
<li><b>Admin password:</b> <code>ODOO_ADMIN_PASSWORD=&lt;your pw&gt;</code>
 or <code>ODOO_ADMIN_PASSWORD=generate</code>
 <span class="muted">(minted, login-verified, shown once in the deploy
 logs; no email confirmation needed for the root admin &mdash; change the
 password after first login)</span></li>
</ol>
<p class="muted">Postgres is this image's system of record. (The Rust
transcode's lance-graph V3 storage lane is a separate odoo-rs deployment,
not this container.)</p>
</body></html>"""


class Onboarding(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 (stdlib API name)
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # keep Railway logs quiet; health checks poll frequently


port = int(os.environ.get("HTTP_PORT", "8069"))
http.server.ThreadingHTTPServer(("0.0.0.0", port), Onboarding).serve_forever()
PYEOF
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

# Legacy first-boot bootstrap (comma-separated module list). SKIPPED when
# ODOO_DB_SETUP drives setup — that path owns first-boot and must NOT inject
# --stop-after-init into the serve argv, or the container would init and exit
# instead of serving (codex P2). So the two variables can be left set together:
# ODOO_DB_SETUP wins, ODOO_INIT_MODULES is the standalone legacy path.
if [[ -n "${ODOO_INIT_MODULES:-}" ]] && ! is_truthy "${ODOO_DB_SETUP:-}"; then
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
        if [[ "$ONBOARDING_NEEDED" == "1" ]] && [[ "${ODOO_ONBOARDING:-1}" != "0" ]]; then
            serve_onboarding   # exec's; does not return
        fi
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
