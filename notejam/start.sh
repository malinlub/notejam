#!/bin/sh
python manage.py syncdb --noinput
python manage.py migrate
python manage.py runserver 0.0.0.0:8000
exec "$@"
