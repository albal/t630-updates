# Serves Dell firmware for end-of-life PowerEdge servers over HTTP, for iDRAC's
# "Update from HTTP". The image contains no Dell files: the firmware is
# downloaded from downloads.dell.com into the /repo volume on first start.
#
#   docker build -t t630-updates .
#   docker run -d -p 80:80 -v dell-firmware:/repo -e MODELS=T630 t630-updates

FROM nginx:1.27.3-alpine

# Upgrade expat too: the base image's libexpat is older than python3's pyexpat needs.
RUN apk add --no-cache --upgrade python3 expat

COPY build_repo.py /usr/local/bin/build_repo.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY nginx.conf /etc/nginx/conf.d/default.conf
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/build_repo.py

ENV MODELS=T630
VOLUME ["/repo"]
EXPOSE 80

# Healthy once the catalog exists, i.e. the download has finished.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60m \
  CMD wget -q --spider http://127.0.0.1/Catalog.xml || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
