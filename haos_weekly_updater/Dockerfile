ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:latest
FROM ${BUILD_FROM}

ENV LANG C.UTF-8

# NOTE: dcron runs jobs with a minimal PATH (/usr/bin:/bin) and rejects PATH=
# lines in the crontab, so `ha` is also linked into /usr/bin.
RUN apk add --no-cache \
    jq \
    curl \
    bash \
    tzdata \
    dcron \
    && curl -fsSL https://github.com/home-assistant/cli/releases/download/5.5.0/ha_amd64 \
    -o /usr/local/bin/ha \
    && chmod +x /usr/local/bin/ha \
    && ln -sf /usr/local/bin/ha /usr/bin/ha

ENV HASSIO_TOKEN=${HASSIO_TOKEN}

COPY run.sh /run.sh
COPY update-script.sh /update-script.sh
COPY telegram.sh /telegram.sh
COPY crontab /etc/crontabs/root

RUN chmod +x /run.sh /update-script.sh /telegram.sh

CMD [ "/run.sh" ]