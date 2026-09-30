"""
Django storage classes and mixins for custom storage backends (Azure blob storage).

By default, this is not used but it can be configured by setting the
DEFAULT_FILE_STORAGE and DEFAULT_FILE_STORAGE_HOSTNAME envvars.
See config/settings/production.py.
"""

from functools import cached_property
from urllib.parse import urlsplit
from urllib.parse import urlunsplit

from django.conf import settings
from storages.backends.azure_storage import AzureStorage
from storages.backends.s3 import S3Storage


class OverrideHostnameMixin:
    """
    Override the hostname when outputting URLs.

    This is useful for use with a CDN or when proxying outside of Blob Storage

    See: https://github.com/jschneier/django-storages/pull/658
    """

    # Just the hostname without scheme (eg. 'media.ethicalads.io')
    override_hostname = None

    def url(self, *args, **kwargs):
        url = super().url(*args, **kwargs)

        if self.override_hostname:
            parts = list(urlsplit(url))
            parts[1] = self.override_hostname
            url = urlunsplit(parts)

        return url


class AzureCDNFileStorage(OverrideHostnameMixin, AzureStorage):
    """An Azure Storage backend that uses a CDN and custom hostname for media."""

    override_hostname = getattr(settings, "DEFAULT_FILE_STORAGE_HOSTNAME", None)


class AzureDataStorage(AzureStorage):
    """An Azure Storage backend for private data/backups/etc."""

    azure_container = getattr(settings, "AZURE_DATA_STORAGE_CONTAINER", None) or "data"


class S3CDNFileStorage(OverrideHostnameMixin, S3Storage):
    """
    An S3 Storage backend that uses a CDN and custom hostname for media.

    Ad images must be publicly readable, but files under ``private_prefixes`` are
    not: the bucket policy only grants public read on the other prefixes, so
    their URLs are presigned and expire after AWS_QUERYSTRING_EXPIRE seconds.
    """

    override_hostname = getattr(settings, "DEFAULT_FILE_STORAGE_HOSTNAME", None)
    bucket_name = getattr(settings, "AWS_STORAGE_BUCKET_NAME", None)
    private_prefixes = ("advertiser_logos/", "flight_logos/", "payouts/")

    @cached_property
    def signed_storage(self):
        return S3Storage(bucket_name=self.bucket_name, querystring_auth=True)

    def url(self, name, *args, **kwargs):
        # The signature is bound to the bucket host, so skip the hostname override
        if name.startswith(self.private_prefixes):
            return self.signed_storage.url(name, *args, **kwargs)
        return super().url(name, *args, **kwargs)


class S3DataStorage(S3Storage):
    """An S3 Storage backend for private data/backups/etc."""

    bucket_name = getattr(settings, "AWS_DATA_STORAGE_BUCKET_NAME", None)
