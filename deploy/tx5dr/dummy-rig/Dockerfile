FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends libhamlib-utils \
    && rm -rf /var/lib/apt/lists/*

EXPOSE 4532

CMD ["rigctld", "-m", "1", "-T", "0.0.0.0", "-t", "4532"]
