# Changelog

This file tracks the CitizenKid fork of the Ethical Ad Server. Upstream releases
from readthedocs/ethical-ad-server are documented in `CHANGELOG.rst`; versions
here are suffixed with `-citizenkid.N` and state which upstream release they
are based on.

## [5.44.0-citizenkid.1] - 2026-08-16

Based on upstream v5.44.0. First fork release, adding a production deployment
path for Clever Cloud.

### Added

- Production `Dockerfile`: multi-stage build (node for the webpack bundle, uv for
  the Python environment with the `production` extra only), running collectstatic
  at build time and serving through gunicorn. Produces a 391MB image against the
  1.73GB development one.
- `deploy/entrypoint.sh` selecting the process to run (`web`, `worker`, `beat`,
  `migrate`, `manage`), listening on `CC_DOCKER_EXPOSED_HTTP_PORT`, and mapping
  Clever Cloud add-on credentials (`POSTGRESQL_ADDON_*`, `REDIS_*`,
  `CELLAR_ADDON_*`) onto the `DATABASE_URL` / `REDIS_URL` / `AWS_*` settings
  Django expects.
- Optional boot-time download of the GeoIP and IP2Proxy databases, gated by
  `GEOIP_DOWNLOAD_ON_BOOT`, since they need credentials and are too large and
  too short-lived to bake into the image.
- `deploy/clevercloud.env.sample` documenting the environment variables that stay
  under the operator's control, importable with `clever env import`.
- `AWS_S3_ENDPOINT_URL`, `AWS_S3_REGION_NAME` and `AWS_S3_ADDRESSING_STYLE`
  settings in production, required to target an S3-compatible store other than
  AWS such as Clever Cloud Cellar. All default to `None`, leaving the existing
  AWS and Azure behavior unchanged.
- `CLAUDE.md` documenting the architecture, commands and conventions of the
  project for coding agents.

### Changed

- `EMAIL_BACKEND` is now read from the environment instead of being hardcoded to
  SendGrid, and `SENDGRID_API_KEY` defaults to an empty string. Production no
  longer refuses to start without a SendGrid account, and any Django or anymail
  backend can be used.
- `.dockerignore` now also excludes `/static` and `/htmlcov` from the build
  context.
