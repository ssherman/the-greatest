"""Where exports and models live (spec 2 §2): a directory for development
and tests, a private R2 bucket on the home server. Bytes and one-line
pointers only. The five key shapes mirror Recommendations::Paths in Rails;
change both or neither."""

from __future__ import annotations

import os
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

_MISSING_CODES = {"NoSuchKey", "404", "NotFound"}


class Missing(Exception):
    pass


def interactions_key(domain: str, name: str) -> str:
    return f"recommendations/{domain}/interactions/{name}.csv.gz"


def interactions_latest(domain: str) -> str:
    return f"recommendations/{domain}/interactions/latest"


def model_key(domain: str, version: str) -> str:
    return f"recommendations/{domain}/model/{version}.csv.gz"


def manifest_key(domain: str, version: str) -> str:
    return f"recommendations/{domain}/model/{version}.json"


def model_latest(domain: str) -> str:
    return f"recommendations/{domain}/model/latest"


class Local:
    def __init__(self, root: Path) -> None:
        self.root = Path(root)

    def put(self, key: str, data: bytes) -> None:
        path = self.root / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def get(self, key: str) -> bytes:
        path = self.root / key
        if not path.is_file():
            raise Missing(key)
        return path.read_bytes()

    def exists(self, key: str) -> bool:
        return (self.root / key).is_file()

    def read_pointer(self, key: str) -> str | None:
        if not self.exists(key):
            return None
        return self.get(key).decode().strip() or None

    def write_pointer(self, key: str, value: str) -> None:
        self.put(key, f"{value}\n".encode())


class R2:
    ENV_KEYS = (
        "RECOMMENDER_R2_ACCOUNT_ID",
        "RECOMMENDER_R2_ACCESS_KEY",
        "RECOMMENDER_R2_SECRET_KEY",
        "RECOMMENDER_R2_BUCKET",
    )

    def __init__(self, client, bucket: str) -> None:
        self.client = client
        self.bucket = bucket

    @classmethod
    def from_env(cls) -> R2 | None:
        values = [os.environ.get(k) or None for k in cls.ENV_KEYS]
        if all(v is None for v in values):
            return None
        if any(v is None for v in values):
            raise RuntimeError(f"{', '.join(cls.ENV_KEYS)} must all be set or all be unset")
        account, access, secret, bucket = values
        client = boto3.client(
            "s3",
            endpoint_url=f"https://{account}.r2.cloudflarestorage.com",
            aws_access_key_id=access,
            aws_secret_access_key=secret,
            region_name="auto",
            # R2 rejects boto3's default checksum headers; the Rails client sets the same.
            config=Config(
                request_checksum_calculation="when_required",
                response_checksum_validation="when_required",
            ),
        )
        return cls(client, bucket)

    def put(self, key: str, data: bytes) -> None:
        self.client.put_object(Bucket=self.bucket, Key=key, Body=data)

    def get(self, key: str) -> bytes:
        try:
            return self.client.get_object(Bucket=self.bucket, Key=key)["Body"].read()
        except ClientError as error:
            if error.response["Error"]["Code"] in _MISSING_CODES:
                raise Missing(key) from error
            raise

    def exists(self, key: str) -> bool:
        try:
            self.client.head_object(Bucket=self.bucket, Key=key)
            return True
        except ClientError as error:
            if error.response["Error"]["Code"] in _MISSING_CODES:
                return False
            raise

    def read_pointer(self, key: str) -> str | None:
        try:
            return self.get(key).decode().strip() or None
        except Missing:
            return None

    def write_pointer(self, key: str, value: str) -> None:
        self.put(key, f"{value}\n".encode())
