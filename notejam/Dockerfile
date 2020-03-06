FROM python:2.7-alpine
ENV PYTHONUNBUFFERED 1
ENV DB_HOST=notejam-db-cluster.cluster-ct6ebwghx7pw.us-west-2.rds.amazonaws.com
RUN mkdir /notejam
WORKDIR /notejam
COPY requirements.txt /notejam/
RUN apk update \
    && apk add --no-cache --virtual .build-deps musl-dev gcc mariadb-dev \
    && pip wheel -r requirements.txt --no-cache-dir --no-input \
    && pip install -r requirements.txt \
    && apk del .build-deps musl-dev gcc mariadb-dev \
    && apk add --no-cache mariadb-connector-c-dev
COPY . /notejam/



COPY ./start.sh /notejam/
ENTRYPOINT ["/notejam/start.sh"]
