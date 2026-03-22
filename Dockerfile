# syntax=docker/dockerfile:1.4

FROM perl:5.40-slim

ENV PERL_CPANM_OPT="--notest" \
    PLACK_ENV=deployment \
    PORT=5000 \
    ZENGIN_PL_API_BACKEND_CLASS=Zengin::Pl

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

RUN cpanm App::cpanminus

COPY cpanfile /app/cpanfile
RUN cpanm --installdeps /app

ARG ZENGIN_PL_GIT_URL=https://github.com/sironekotoro/zengin-pl.git
ARG ZENGIN_PL_GIT_REF=
RUN git clone --depth 1 "${ZENGIN_PL_GIT_URL}" /tmp/zengin-pl \
    && if [ -n "${ZENGIN_PL_GIT_REF}" ]; then \
        git -C /tmp/zengin-pl fetch --depth 1 origin "${ZENGIN_PL_GIT_REF}" \
        && git -C /tmp/zengin-pl checkout FETCH_HEAD; \
    fi \
    && cpanm --installdeps /tmp/zengin-pl \
    && cpanm /tmp/zengin-pl \
    && rm -rf /tmp/zengin-pl

COPY . /app

EXPOSE 5000

CMD ["sh", "-c", "plackup -Ilib -p ${PORT} app.psgi"]
