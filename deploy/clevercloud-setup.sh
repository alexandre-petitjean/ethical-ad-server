#!/usr/bin/env bash
#
# Recreates the whole Clever Cloud setup for the ad server from scratch:
# three applications sharing one image, three add-ons, and the environment
# each application needs.
#
# This script is meant to be READ and run step by step rather than blindly:
# it creates billable resources and it needs two values only you can provide
# (the organisation and the Cellar bucket names).
#
# Prerequisites:
#   - clever-tools installed and logged in (clever login)
#   - the repository checked out, with a Dockerfile at its root
#
# Everything is idempotent-ish but NOT re-runnable as is: `clever create`
# fails if an application of that name already exists.

set -euo pipefail

# ---------------------------------------------------------------------------
# Settings to review before running
# ---------------------------------------------------------------------------

ORG="orga_xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"   # clever organisations
REGION="par"

APP_WEB="ethical-ad-django"
APP_WORKER="ethical-ad-worker"
APP_MIGRATE="ethical-ad-migrate"

ADDON_PG="ethical-ad-postgres"
ADDON_REDIS="ethical-ad-redis"
ADDON_CELLAR="ethical-ad-s3"

# The Cellar add-on gives you credentials, never buckets: create these two in
# the console (or with an S3 client) before any advertiser uploads an image.
BUCKET_MEDIA="citizenkid-ads-media"
BUCKET_DATA="citizenkid-ads-data"

# PostgreSQL "dev" plan allows only 5 simultaneous connections, which is why
# CONN_MAX_AGE is forced to 0 below. Move to xxs_sml (45 connections) before
# scaling anything up.
PLAN_PG="dev"
PLAN_REDIS="s_mono"
PLAN_CELLAR="S"

# ---------------------------------------------------------------------------
# 1. Add-ons
# ---------------------------------------------------------------------------

clever addon create postgresql-addon "$ADDON_PG"     --plan "$PLAN_PG"     --region "$REGION" --org "$ORG"
clever addon create redis-addon      "$ADDON_REDIS"  --plan "$PLAN_REDIS"  --region "$REGION" --org "$ORG"
clever addon create cellar-addon     "$ADDON_CELLAR" --plan "$PLAN_CELLAR" --region "$REGION" --org "$ORG"

# ---------------------------------------------------------------------------
# 2. Applications
#
# All three are Docker applications built from the same root Dockerfile; they
# differ only by the PROCESS_TYPE set further down.
# ---------------------------------------------------------------------------

clever create --type docker "$APP_WEB"    --alias web    --region "$REGION" --org "$ORG"
clever create --type docker "$APP_WORKER" --alias worker --region "$REGION" --org "$ORG"

# The migration runner is a Task: it runs its command, then stops, and is
# billed per second of execution.
clever create --type docker "$APP_MIGRATE" --alias migrate --region "$REGION" --org "$ORG" \
    --task "/app/deploy/entrypoint.sh migrate"

# ---------------------------------------------------------------------------
# 3. Link every add-on to every application
#
# Linking injects POSTGRESQL_ADDON_*, REDIS_* and CELLAR_ADDON_* automatically.
# deploy/entrypoint.sh maps those onto DATABASE_URL / REDIS_URL / AWS_*, so no
# credential is ever copied by hand.
# ---------------------------------------------------------------------------

for alias in web worker migrate; do
    for addon in "$ADDON_PG" "$ADDON_REDIS" "$ADDON_CELLAR"; do
        clever service link-addon "$addon" --alias "$alias"
    done
done

# ---------------------------------------------------------------------------
# 4. Shared environment
#
# Copy deploy/clevercloud.env.sample, fill in SECRET_KEY, ALLOWED_HOSTS and the
# bucket names, then import it into the three applications. `clever env import`
# REPLACES all manually set variables, so import first and set per-application
# variables afterwards.
# ---------------------------------------------------------------------------

ENV_FILE="${ENV_FILE:-deploy/clevercloud.env}"   # your filled-in copy of the sample

for alias in web worker migrate; do
    clever env import --alias "$alias" < "$ENV_FILE"
done

# ---------------------------------------------------------------------------
# 5. Per-application settings
#
# PROCESS_TYPE selects the process. Do NOT use CC_RUN_COMMAND: on the Docker
# runtime it does not override the image's ENTRYPOINT/CMD, so every application
# would silently start a web server instead.
# ---------------------------------------------------------------------------

clever env set PROCESS_TYPE web              --alias web
clever env set GUNICORN_WORKERS 2            --alias web

clever env set PROCESS_TYPE worker           --alias worker
clever env set CELERY_EMBED_BEAT true        --alias worker
clever env set CELERY_CONCURRENCY 2          --alias worker
# A celery worker listens on no port, and Clever fails the deployment of any
# non-task application when nothing answers on CC_DOCKER_EXPOSED_HTTP_PORT.
clever env set WORKER_HTTP_HEALTHCHECK true  --alias worker

clever env set PROCESS_TYPE migrate          --alias migrate

# The embedded beat scheduler must exist exactly once: a second instance would
# fire every periodic task twice.
clever scale --alias worker --min-instances 1 --max-instances 1

# ---------------------------------------------------------------------------
# 6. Deploy
#
# The web application can also be wired to GitHub from the console, in which
# case pushing to the default branch deploys it and `clever deploy --alias web`
# is not needed.
# ---------------------------------------------------------------------------

clever deploy --alias web
clever deploy --alias worker
clever deploy --alias migrate     # runs the migrations, then stops

# Re-run the migrations later without a new build:
#   clever restart --alias migrate

# ---------------------------------------------------------------------------
# 7. First-run steps that no environment variable covers
# ---------------------------------------------------------------------------

# Point the Django Site at the real domain, otherwise every view/click URL the
# decision API returns points at example.com and no impression is ever tracked:
#
#   clever env set PROCESS_TYPE "manage" --alias migrate   # then adapt the task command
#
# In practice it is simpler to run these against the add-on from a local
# container built from the same image:
#
#   docker run --rm --env-file <env-with-DATABASE_URL> ethical-ad-server:prod \
#       manage shell -c "from django.contrib.sites.models import Site; \
#           s=Site.objects.get_current(); s.domain='ads.example.com'; \
#           s.name='CitizenKid Ad Server'; s.save()"
#
#   docker run --rm --env-file <env-with-DATABASE_URL> \
#       -e DJANGO_SUPERUSER_PASSWORD='...' ethical-ad-server:prod \
#       manage createsuperuser --noinput --email you@example.com
#
# Restart the web application afterwards: django.contrib.sites caches the Site
# in process memory, so the change is invisible until the process restarts.
#
#   clever restart --alias web
