#!/usr/bin/env bash
#
# Entrypoint for the production image.
#
# The process to run is selected by the PROCESS_TYPE environment variable, or
# by the first argument when that variable is unset:
#
#   web     gunicorn serving config.wsgi (the image default)
#   worker  celery worker
#   beat    celery beat  -- run exactly ONE instance, never scale it horizontally
#   migrate apply migrations and exit (suitable for a Clever Task)
#   manage  run any manage.py command, e.g. `manage createsuperuser`
#
# Anything else is executed verbatim, so `docker run <image> bash` still works.
#
# PROCESS_TYPE deliberately takes precedence over the argument: on Clever
# Cloud's Docker runtime, CC_RUN_COMMAND does NOT override an image's
# ENTRYPOINT/CMD, so the CMD below would always win and every application would
# start a web server. Selecting the process through the environment is the only
# thing that works there. Locally, `docker run <image> worker` still does what
# it looks like, because PROCESS_TYPE is unset.

set -euo pipefail

PROCESS_TYPE="${PROCESS_TYPE:-${1:-web}}"

# Clever Cloud tells the container which port to listen on; 8080 is its default.
PORT="${CC_DOCKER_EXPOSED_HTTP_PORT:-${PORT:-8080}}"

log() {
    echo "[entrypoint] $*" >&2
}

urlencode() {
    python -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Clever Cloud injects add-on credentials under its own variable names when an
# add-on is linked to an application. Django reads DATABASE_URL / REDIS_URL /
# AWS_*, so bridge the two here rather than duplicating secrets by hand in the
# application's environment. Anything set explicitly always wins, which keeps
# this a no-op on other platforms.
map_addon_variables() {
    # PostgreSQL: prefer the ready-made URI, fall back to the components.
    if [ -z "${DATABASE_URL:-}" ]; then
        if [ -n "${POSTGRESQL_ADDON_URI:-}" ]; then
            export DATABASE_URL="${POSTGRESQL_ADDON_URI}"
            log "DATABASE_URL derived from POSTGRESQL_ADDON_URI"
        elif [ -n "${POSTGRESQL_ADDON_HOST:-}" ]; then
            export DATABASE_URL="postgresql://$(urlencode "${POSTGRESQL_ADDON_USER}"):$(urlencode "${POSTGRESQL_ADDON_PASSWORD}")@${POSTGRESQL_ADDON_HOST}:${POSTGRESQL_ADDON_PORT:-5432}/${POSTGRESQL_ADDON_DB}"
            log "DATABASE_URL derived from POSTGRESQL_ADDON_* components"
        fi
    fi

    # Redis: the add-on exposes host/port/password, never a URI.
    if [ -z "${REDIS_URL:-}" ] && [ -n "${REDIS_HOST:-}" ]; then
        export REDIS_URL="redis://:$(urlencode "${REDIS_PASSWORD:-}")@${REDIS_HOST}:${REDIS_PORT:-6379}/0"
        log "REDIS_URL derived from REDIS_HOST/REDIS_PORT/REDIS_PASSWORD"
    fi

    # Cellar (S3-compatible object storage) for advertiser-uploaded images.
    # The bucket is not part of the add-on, so AWS_STORAGE_BUCKET_NAME and
    # AWS_DATA_STORAGE_BUCKET_NAME stay under your control.
    if [ -z "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${CELLAR_ADDON_KEY_ID:-}" ]; then
        export AWS_ACCESS_KEY_ID="${CELLAR_ADDON_KEY_ID}"
        export AWS_SECRET_ACCESS_KEY="${CELLAR_ADDON_KEY_SECRET}"
        export AWS_S3_ENDPOINT_URL="${AWS_S3_ENDPOINT_URL:-https://${CELLAR_ADDON_HOST}}"
        # Cellar requires path-style addressing
        export AWS_S3_ADDRESSING_STYLE="${AWS_S3_ADDRESSING_STYLE:-path}"
        log "S3 credentials derived from CELLAR_ADDON_* (endpoint ${AWS_S3_ENDPOINT_URL})"
    fi
}

# The GeoIP and IP2Proxy databases are ~70MB and need credentials
# (MAXMIND_LICENSE_KEY, IP2LOCATION_TOKEN), so they are not baked into the image
# where they would be both stale and leaked. Instances are ephemeral, so fetch
# them at boot when the credentials are present. Without them the ad server
# still serves ads, but all geo targeting silently matches nothing.
download_ip_databases() {
    if [ "${GEOIP_DOWNLOAD_ON_BOOT:-false}" != "true" ]; then
        return 0
    fi

    local outdir="${GEOIP_GEOLITE2_PATH:-/app/geoip}"
    mkdir -p "$outdir"

    if [ -n "${MAXMIND_LICENSE_KEY:-}" ]; then
        log "Downloading GeoIP databases into ${outdir}"
        python geoip/database-updater.py --geoip-only --outdir="$outdir" \
            || log "WARNING: GeoIP download failed, continuing without geolocation"
    else
        log "MAXMIND_LICENSE_KEY unset, skipping GeoIP download"
    fi

    if [ -n "${IP2LOCATION_TOKEN:-}" ]; then
        log "Downloading IP2Proxy database into ${outdir}"
        python geoip/database-updater.py --ipproxy-only --outdir="$outdir" \
            || log "WARNING: IP2Proxy download failed, continuing without proxy detection"
    fi
}

# Opt-in only. Running migrations from every booting instance races when more
# than one is starting; prefer a dedicated Clever Task running `migrate`.
# Never run makemigrations here: with the analyzer app disabled, Django would
# generate a bogus migration for the AnalyzedUrl models.
apply_migrations() {
    if [ "${RUN_MIGRATIONS:-false}" = "true" ]; then
        log "Applying database migrations"
        python manage.py migrate --noinput
    fi
}

start_web() {
    apply_migrations
    download_ip_databases

    # Default worker class is sync, matching the upstream Procfile. The image
    # ships gunicorn[gevent], so GUNICORN_WORKER_CLASS=gevent is available for
    # the I/O-bound decision API once it has been load tested.
    local cmd=(
        gunicorn config.wsgi
        --bind "0.0.0.0:${PORT}"
        --workers "${GUNICORN_WORKERS:-3}"
        --worker-class "${GUNICORN_WORKER_CLASS:-sync}"
        --timeout "${GUNICORN_TIMEOUT:-30}"
        --max-requests "${GUNICORN_MAX_REQUESTS:-10000}"
        --max-requests-jitter "${GUNICORN_MAX_REQUESTS_JITTER:-1000}"
        --access-logfile -
        --error-logfile -
    )

    if [ -n "${NEW_RELIC_LICENSE_KEY:-}" ]; then
        log "Starting gunicorn on :${PORT} under New Relic"
        exec newrelic-admin run-program "${cmd[@]}"
    fi

    log "Starting gunicorn on :${PORT}"
    exec "${cmd[@]}"
}

start_worker() {
    download_ip_databases

    # A celery worker listens on no port, and Clever Cloud fails the deployment
    # of any non-task application when nothing answers on
    # CC_DOCKER_EXPOSED_HTTP_PORT ("Nothing listening on 0.0.0.0:8080").
    # This tiny responder exists only to satisfy that check.
    if [ "${WORKER_HTTP_HEALTHCHECK:-false}" = "true" ]; then
        log "Starting health check responder on :${PORT}"
        python /app/deploy/healthcheck_server.py "${PORT}" &
    fi

    local cmd=(
        celery --app=config.celery_app.app worker
        --loglevel="${CELERY_LOG_LEVEL:-INFO}"
        --concurrency="${CELERY_CONCURRENCY:-2}"
        --max-tasks-per-child "${CELERY_MAX_TASKS_PER_CHILD:-1000}"
        --without-gossip
        --without-mingle
        --without-heartbeat
    )

    # CELERY_EMBED_BEAT runs the scheduler inside this worker, so a single
    # application covers both roles. Only safe with exactly ONE worker instance:
    # every embedded scheduler fires the whole beat schedule, so a second
    # instance would run every periodic task twice. Keep the application at one
    # instance with autoscaling off, or split beat into its own application
    # (PROCESS_TYPE=beat) before scaling out.
    if [ "${CELERY_EMBED_BEAT:-false}" = "true" ]; then
        cmd+=(--beat --schedule="${CELERY_BEAT_SCHEDULE_FILE:-/tmp/celerybeat-schedule}")
        log "Starting celery worker with embedded beat"
    else
        log "Starting celery worker"
    fi

    exec "${cmd[@]}"
}

start_beat() {
    # The schedule database is written on every tick; keep it off the app
    # directory since the container filesystem is ephemeral anyway.
    log "Starting celery beat"
    exec celery --app=config.celery_app.app beat \
        --loglevel="${CELERY_LOG_LEVEL:-INFO}" \
        --schedule="${CELERY_BEAT_SCHEDULE_FILE:-/tmp/celerybeat-schedule}"
}

map_addon_variables

case "$PROCESS_TYPE" in
    web)
        start_web
        ;;
    worker)
        start_worker
        ;;
    beat)
        start_beat
        ;;
    migrate)
        log "Applying database migrations"
        exec python manage.py migrate --noinput
        ;;
    manage)
        shift
        exec python manage.py "$@"
        ;;
    *)
        exec "$@"
        ;;
esac
