from django.urls import include, path
from django.shortcuts import redirect


urlpatterns = [
    path("", lambda request: redirect("notes:list", permanent=False)),
    path("notes/", include("notes.urls", namespace="notes")),
]
