from django.apps import AppConfig


class NotesConfig(AppConfig):
    name = "notes"
    default_auto_field = "django.db.models.BigAutoField"

    def ready(self):
        # Open the pyx Db once per process, on first request the lazy
        # accessor in pyx_store will pick it up. We don't open here
        # eagerly because Django's `runserver` autoreloader spawns
        # multiple processes during reload — opening pyx twice in the
        # same parent run is fine because it's still one writer at a
        # time, but eager init in `ready()` would also fire under
        # `manage.py check` etc.
        pass
