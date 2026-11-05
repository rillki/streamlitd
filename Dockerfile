# Build and run a streamlitd app in a container.
#   docker build --build-arg APP=examples/prod -t my-streamlitd-app .
#   docker run -p 8501:8501 my-streamlitd-app
# APP is the directory of the dub project to build (its dub.json depends on streamlitd).

FROM ubuntu:24.04 AS build
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ldc dub gcc libc6-dev libssl-dev zlib1g-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
ARG APP=examples/hello
RUN cd "$APP" && dub build --compiler=ldc2 --build=release \
    && cp "$(dub describe --compiler=ldc2 --data=target-path --data-list | head -1)$(dub describe --compiler=ldc2 --data=target-name --data-list | head -1)" /app-bin \
    && mkdir -p /app-data/.streamlitd \
    && (cp .streamlitd/config.toml /app-data/.streamlitd/ 2>/dev/null || cp .streamlit/config.toml /app-data/.streamlitd/ 2>/dev/null || true)

FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libphobos2-ldc-shared106 libssl3 zlib1g ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home /app app
WORKDIR /app
COPY --from=build /app-bin /app/app
# Only config.toml is copied. Secrets are never baked into the image; mount them at runtime:
#   docker run -v $PWD/.streamlitd/secrets.toml:/app/.streamlitd/secrets.toml:ro ...
COPY --from=build /app-data/ /app/
USER app
EXPOSE 8501
HEALTHCHECK --interval=30s --timeout=3s CMD [ "sh", "-c", "exec 3<>/dev/tcp/127.0.0.1/8501" ]
ENTRYPOINT ["/app/app", "--host", "0.0.0.0", "--port", "8501"]
