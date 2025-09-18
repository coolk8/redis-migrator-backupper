FROM ubuntu:jammy

ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y redis build-essential python3 python3-pip gzip \
    && pip3 install rdbtools python-lzf

WORKDIR /app

COPY --chmod=755 migrate.sh ./

CMD bash migrate.sh
