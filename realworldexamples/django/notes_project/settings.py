"""Minimal Django settings for the pyx notes example.

Notable differences from a stock Django project:
- No `DATABASES`. We don't use the Django ORM — pyx is the only store.
  Django still complains during system checks if `DATABASES` is empty
  on some versions, so we point at an in-memory SQLite that we never
  actually touch (sessions are signed-cookie-based; auth is unused).
- `MIDDLEWARE` is trimmed: no auth, no sessions DB-backed, no admin.
- Single-process deployment is assumed; see this example's README.
"""
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = "dev-only-do-not-deploy"  # rotate before deploying
DEBUG = True
ALLOWED_HOSTS = ["*"]

INSTALLED_APPS = [
    "django.contrib.contenttypes",
    "django.contrib.staticfiles",
    "notes",
]

MIDDLEWARE = [
    "django.middleware.common.CommonMiddleware",
]

ROOT_URLCONF = "notes_project.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {"context_processors": []},
    },
]

WSGI_APPLICATION = "notes_project.wsgi.application"

# Stub DATABASES — Django insists on having one, but the notes app
# doesn't touch it. All real storage lives in pyx (see notes/pyx_store.py).
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": ":memory:",
    },
}

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

STATIC_URL = "static/"
USE_TZ = True

# Where the pyx file lives. Change this for prod (e.g. /var/lib/notes.pyx).
PYX_PATH = str(BASE_DIR / "notes.pyx")
