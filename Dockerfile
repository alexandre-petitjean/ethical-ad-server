# syntax=docker/dockerfile:1

# Production image for the Ethical Ad Server.
#
# Targets Clever Cloud's Docker runtime, but has nothing Clever-specific in it:
# the process to run is chosen by the CMD (web / worker / beat) and the HTTP
# port comes from CC_DOCKER_EXPOSED_HTTP_PORT (or PORT), defaulting to 8080.
#
#   docker build -t ethical-ad-server:prod .
#   docker run --rm -p 8080:8080 --env-file .envs/prod ethical-ad-server:prod web
#
# The local development stack (docker-compose.yml) is unaffected and still uses
# docker-compose/django/Dockerfile.


# ---------------------------------------------------------------------------
# Stage 1 - frontend assets
#
# assets/dist is gitignored and STORAGES["staticfiles"] is Whitenoise's
# CompressedManifestStaticFilesStorage, so the webpack bundle must exist before
# collectstatic runs or the manifest is incomplete and templates raise at runtime.
# The full node image is used (not -slim) because devDependencies are pulled
# from git and need a git client.
# ---------------------------------------------------------------------------
FROM node:24 AS frontend

WORKDIR /build

COPY package.json package-lock.json ./
RUN npm clean-install --no-audit --no-fund

COPY webpack.config.js ./
COPY assets/ ./assets/

RUN npm run build


# ---------------------------------------------------------------------------
# Stage 2 - python dependencies
#
# Only the "production" extra is installed. The "analyzer" extra is deliberately
# left out: it pulls spaCy plus a ~30MB language model and would multiply the
# image size. Add `--extra analyzer` here if ADSERVER_ANALYZER_BACKEND is set.
# ---------------------------------------------------------------------------
FROM python:3.12-slim-bookworm AS builder

# Pinned to the same uv version as CI (.github/workflows/ci.yml)
COPY --from=ghcr.io/astral-sh/uv:0.11.1 /uv /uvx /bin/

ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_PYTHON_DOWNLOADS=never

# Most dependencies ship manylinux wheels; build-essential is kept as a fallback
# so a dependency without a wheel doesn't break the build. This stage is discarded.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    uv sync --frozen --no-dev --no-install-project --extra production


# ---------------------------------------------------------------------------
# Stage 3 - runtime
# ---------------------------------------------------------------------------
FROM python:3.12-slim-bookworm AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/venv/bin:$PATH" \
    DJANGO_SETTINGS_MODULE=config.settings.production

# tini reaps zombies and forwards signals, which matters for celery workers.
# curl is kept for health checks and debugging from a running instance.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 adserver

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY --chown=adserver:adserver . /app
COPY --from=frontend --chown=adserver:adserver /build/assets/dist /app/assets/dist

RUN chmod +x /app/deploy/entrypoint.sh

# collectstatic needs the production settings to import, and those settings
# require SECRET_KEY / ALLOWED_HOSTS / DATABASE_URL / REDIS_URL / SENDGRID_API_KEY.
# The values below exist only for the duration of this layer; nothing connects
# to a database or a broker. File storage is forced to the local filesystem so
# the default Azure backend isn't instantiated at build time.
RUN SECRET_KEY=build-time-only \
    ALLOWED_HOSTS=localhost \
    DATABASE_URL=sqlite:///build.sqlite3 \
    REDIS_URL=redis://localhost:6379/0 \
    SENDGRID_API_KEY=build-time-only \
    DEFAULT_FILE_STORAGE=django.core.files.storage.FileSystemStorage \
    DATA_STORAGE=django.core.files.storage.FileSystemStorage \
    python manage.py collectstatic --noinput --clear \
    && rm -f build.sqlite3

USER adserver

# Overridden by CC_DOCKER_EXPOSED_HTTP_PORT on Clever Cloud
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/app/deploy/entrypoint.sh"]
CMD ["web"]
