from django.urls import path
from . import views

app_name = "notes"

urlpatterns = [
    path("", views.list_view, name="list"),
    path("new/", views.create_view, name="create"),
    path("<int:doc_id>/", views.detail_view, name="detail"),
    path("<int:doc_id>/edit/", views.edit_view, name="edit"),
    path("<int:doc_id>/delete/", views.delete_view, name="delete"),
]
