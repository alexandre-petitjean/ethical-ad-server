# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` in this directory is the authoritative project standards document — read it too. This file adds the architectural map that requires reading several files to reconstruct.

## Commands

Python is managed with **uv** (Python 3.12 only, pinned in `pyproject.toml`). Everything below runs from this directory.

```bash
tox                                    # full CI equivalent: coverage, styles, migrations, docs
tox -e py3 -- adserver/tests/test_api.py   # single test file, no coverage
uv run pytest -- adserver/tests/test_api.py -k SomeTestClass
uv run pre-commit run --all-files      # ruff lint + format, django-upgrade, uv-lock
uv run python manage.py makemigrations # REQUIRED after any models.py change
npm run build                          # webpack assets (npm run watch to rebuild on change)
```

- `tox` env list is defined in `pyproject.toml` (`[tool.tox]`): `coverage`, `styles`, `migrations`, `docs`. `py3` is *not* in the default list — it exists only for running a targeted test.
- **Coverage gate: `--fail-under=94`.** Inspect `htmlcov/` for missed lines.
- Tests run under `DJANGO_SETTINGS_MODULE=config.settings.testing` (which inherits `development.py`, which inherits `base.py`). `manage.py` defaults to `config.settings.development`.
- The `migrations` tox env runs `makemigrations --check --dry-run`; a forgotten migration fails CI.
- CI (`.github/workflows/ci.yml`) is just `uv run tox` on every push.

### Docker stack

```bash
cp .envs/local/django.sample .envs/local/django   # once; .envs/local/django is gitignored
make dockerbuild                                  # slow, once
make dockerserve                                  # django:5000, postgres, redis, celeryworker, celerybeat, frontend
make dockershell                                  # then: uv run ./manage.py createsuperuser
```

The `metabase` service is commented out in `docker-compose.yml`; Metabase embedding on the Django side is still configured via `METABASE_*` settings.

## Architecture

Django project config lives in `config/`; the single core app is `adserver/`. Settings are split `base.py` → `development.py` → `testing.py` / `production.py` and are almost entirely `django-environ`-driven.

### The serving hot path

1. `POST /api/v1/decision/` → `adserver/api/views.py::AdDecisionView`. This is the endpoint ad clients hit; treat it as latency-sensitive.
2. It delegates to a decision backend selected by `ADSERVER_DECISION_BACKEND` (`adserver/decisionengine/backends.py`). Class chain: `BaseAdDecisionBackend` → `AdvertisingEnabledBackend` (candidate flight query + `filter_flight`) → `ProbabilisticFlightBackend` (default; weights flights by remaining capacity, then weights ads within a flight by CTR and embedding similarity). `AdvertisingDisabledBackend` is the opt-out path.
3. The winning `Advertisement.offer_ad(...)` (`adserver/models.py`) writes an `Offer` row and mints a **nonce** embedded in the returned view/click URLs.
4. The client calls back into `BaseProxyView` subclasses in `adserver/views.py` — `AdViewProxyView`, `AdClickProxyView`, `AdViewTimeProxyView` — which validate the nonce (`Advertisement.is_valid_offer` / `invalidate_nonce`) and run `ignore_tracking_reason()`, the fraud gate (bots, blocklisted UA/referrer/IP, internal IPs, logged-in users, ASN rate limits, geo mismatch). Only impressions that pass become billable `View` / `Click` rows.

`Offer`, `View`, `Click` all subclass `AdBase`. `Offer` uses a UUIDv7 primary key and can be redirected to a separate table via `ADSERVER_OFFER_DB_TABLE` (offers are archived out by `adserver/management/commands/archive_offers.py`).

### Domain model

`Advertiser → Campaign → Flight → Advertisement`, served to `Publisher`s (grouped by `PublisherGroup`) rendered as an `AdType`. Targeting dimensions: `Topic`, `Keyword`, `Region` / `CountryRegion`, plus country/metro data resolved by middleware. Campaign types are in `adserver/constants.py` (`paid`, `affiliate`, `community`, `publisher-house`, `house`) and drive both eligibility and revenue splits.

Most business objects extend `IndestructibleModel` — they cannot be hard-deleted, and querysets refuse `.delete()`. Design around that instead of trying to remove rows.

### Reporting pipeline

Raw events are never queried directly for dashboards. Celery tasks in `adserver/tasks.py` (`daily_update_*`, orchestrated by `daily_update_reports` / `update_previous_day_reports`) roll `Offer`/`View`/`Click` up into the `*Impression` aggregate tables (`AdImpression`, `GeoImpression`, `KeywordImpression`, `PlacementImpression`, `RegionImpression`, `RegionTopicImpression`, `UpliftImpression`, `DomainImpression`, `RotationImpression`, `AdvertiserImpression`, `PublisherImpression`…). All subclass `BaseImpression`.

Reads of those aggregate models are routed to a read replica by `adserver/router.py::ReplicaRouter` when `DATABASE_ROUTER` is set — a model added to the reporting set must be added to `index_models` there too.

Report *presentation* is a three-layer split: report classes in `adserver/reports.py` (`AdvertiserReport`, `PublisherReport`, and the `Optimized*` variants) do the aggregation; mixins in `adserver/mixins.py` (`ReportQuerysetMixin`, `GeoReportMixin`, `KeywordReportMixin`, `AllReportMixin`) supply the queryset and access control; the `*ReportView` classes in `adserver/views.py` are thin. Refunds (`Offer.refund()`) decrement `AdImpression` but deliberately do not touch the other denormalized indexes.

Note: `Flight.total_views` / `total_clicks` are **not** updated in real time (lock contention); `refresh_flight_denormalized_totals` reconciles them periodically.

### Access control

Views use `AdvertiserAccessMixin` / `PublisherAccessMixin` and their `*AdminAccessMixin` / `*ManagerAccessMixin` variants from `adserver/mixins.py` combined with `UserPassesTestMixin`, not raw permission checks. Custom user model is `adserver_auth.User` (`adserver/auth/`), with django-allauth + MFA and a custom account adapter.

### Peripheral subsystems

- **`adserver/analyzer/`** — publisher page keyword/topic extraction and embeddings. Enabled only when `ADSERVER_ANALYZER_BACKEND` is set; backends in `analyzer/backends/` (`naive`, `textacynlp`, `eatopics`). Pulls in the heavy `analyzer` optional dependency group (spaCy, OpenAI, duckdb, pgvector). Testing settings force the `naive` backend.
- **`ethicalads_ext`** — proprietary sibling package, auto-detected at `../ethicalads-ext` in `config/settings/base.py`, which sets `ADSERVER_EXT` and conditionally appends `ethicalads_ext.{embedding,etl,support}` to `INSTALLED_APPS`. Testing strips those apps unless `TESTING_EXT=1`. Guard any code that touches it with an `INSTALLED_APPS` check, as `adserver/api/urls.py` does.
- **Payments** — Stripe via dj-stripe; `adserver/hooks.py` holds webhook handlers, `PublisherPayout` + `PAYOUT_*` constants cover the publisher payout side (Stripe Connect flow in `PublisherStripeConnectView`/`PublisherStripeReturnView`).
- **`frontbackend/`** — a Django email backend that sends/creates drafts through Front (front.com) instead of SMTP.
- **Middleware** (`adserver/middleware.py`) — IP and geolocation resolution is pluggable: `ADSERVER_IPADDRESS_MIDDLEWARE` / `ADSERVER_GEOIP_MIDDLEWARE` select between the `XForwardedFor`, `Cloudflare*`, and `GeoIpDatabase` variants. GeoIP databases come from `make geoip` / `make ipproxy`; testing points `GEOIP_PATH` at a nonexistent dir so tests never geolocate.
- **Staff tooling** — `adserver/staff/` (invite advertisers/publishers) and the `Staff*ReportView` classes; `adserver/importers/` + `rtdimport`/`pypi_import` management commands ingest external publisher data.

## Conventions

- Keep views thin — business logic belongs in model methods (there is no `services.py` in `adserver/` today; model methods are where the logic actually lives).
- ruff: single-line imports (`force-single-line`), 2 lines after imports, line-length 88, security lint (`S`) on. `migrations/` and `manage.py` are excluded; tests and `config/settings/*` have targeted ignores in `pyproject.toml`.
- Wrap user-facing strings in `gettext` / `gettext_lazy` (imported as `_`).
- Every feature or fix needs a test in `adserver/tests/test_*.py`; shared fixtures/helpers live in `adserver/tests/common.py`.
- This tree mirrors upstream `readthedocs/ethical-ad-server` — keep changes minimal and upstream-compatible.
