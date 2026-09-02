FROM python:3.12.11-slim-bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libsasl2-dev \
    libldap2-dev \
    libssl-dev \
 && rm -rf /var/lib/apt/lists/*

COPY ./code/requirements.txt /tmp/requirements.txt
RUN pip install --prefix=/install --no-cache-dir -r /tmp/requirements.txt

# Отдельная standalone-сборка (PyInstaller --onefile) для systemd-пути roles/monitoring_agent
# (roles/monitoring_agent/tasks/systemd-ipa-exporter.yml) — не связана с образом выше, у него свой
# CMD/раскладка. Базовый образ — bullseye (glibc 2.31), а не bookworm (glibc 2.36, как у образа
# выше): единственный потребитель systemd-пути — freeipa (roles/freeipa, ADR-0011), который
# всегда Rocky/AlmaLinux 9 (glibc 2.34). PyInstaller статически вкладывает в бинарь
# libpythonX.Y.so, слинкованную против glibc сборочного окружения — бинарь, собранный на bookworm
# (2.36), требовал GLIBC_2.35 и падал на Rocky 9 сразу после старта (см. ROADMAP.md P0-57);
# glibc обратно совместима (бинарь, собранный на более старой версии, запускается и на более
# новой, не наоборот), поэтому bullseye (2.31) — самый старый ещё поддерживаемый апстримом тег
# python-образов, дающий устойчивый запас совместимости, а не подгонка ровно под 2.34.
FROM python:3.12-slim-bullseye AS pyinstaller-build

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libsasl2-dev \
    libldap2-dev \
    libssl-dev \
 && rm -rf /var/lib/apt/lists/*

COPY ./code/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt pyinstaller==6.16.0

COPY ./code /build
WORKDIR /build
RUN pyinstaller --onefile --name freeipa-exporter exporter.py

# Пустой экспорт-стейдж — извлекается отдельно (`docker build --target pyinstaller-artifact
# -o type=local,dest=<dir> .`), не участвует в обычной сборке образа (CMD ниже не трогает).
FROM scratch AS pyinstaller-artifact
COPY --from=pyinstaller-build /build/dist/freeipa-exporter /freeipa-exporter

FROM python:3.12.11-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsasl2-2 \
    libldap-2.5-0 \
    libssl3 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /install /usr/local

COPY ./code /code
WORKDIR /code

CMD ["python", "exporter.py"]