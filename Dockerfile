# Firmware repository for end-of-life Dell PowerEdge servers, served over HTTP
# for iDRAC's "Update from HTTP".
#
#   docker build --build-arg MODELS=T630 -t dell-13g-repo:t630 .
#   docker run -d -p 80:80 dell-13g-repo:t630

FROM python:3.12.8-slim AS fetch
ARG MODELS=T630
ARG CATALOG_URL=https://downloads.dell.com/FOLDER14611037M/1/Catalog.xml.gz
ARG EXTRA_ARGS=""
COPY build_repo.py /usr/local/bin/build_repo.py
RUN python3 -I /usr/local/bin/build_repo.py \
      --models "$MODELS" --catalog-url "$CATALOG_URL" --out /repo $EXTRA_ARGS

FROM nginx:1.27.3-alpine
ARG MODELS=T630
LABEL org.opencontainers.image.description="Final Dell firmware for PowerEdge ${MODELS}, served over HTTP for iDRAC updates"
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=fetch /repo /usr/share/nginx/html
EXPOSE 80
