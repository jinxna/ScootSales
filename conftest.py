import os

import pytest

LOCAL_HOSTS = ("127.0.0.1", "localhost", "[::1]")
EMULATOR_HOSTS = ("FIRESTORE_EMULATOR_HOST", "FIREBASE_AUTH_EMULATOR_HOST", "FIREBASE_STORAGE_EMULATOR_HOST")


def _is_local(value: str) -> bool:
    return value.rsplit(":", 1)[0] in LOCAL_HOSTS


def pytest_configure(config):
    for name in EMULATOR_HOSTS:
        value = os.environ.get(name)
        if value and not _is_local(value):
            pytest.exit(f"Refusing to run: {name} is {value}, not a local emulator.", returncode=4)
    try:
        from google.cloud import firestore
    except ImportError:
        return
    real_init = firestore.Client.__init__

    def emulator_only(self, *args, **kwargs):
        if not _is_local(os.environ.get("FIRESTORE_EMULATOR_HOST", "")):
            raise RuntimeError("Refusing to open Firestore: FIRESTORE_EMULATOR_HOST is not set to a local "
                               "emulator, so this test would reach a real project.")
        real_init(self, *args, **kwargs)

    firestore.Client.__init__ = emulator_only
