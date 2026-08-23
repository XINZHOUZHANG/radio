FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends pulseaudio pulseaudio-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY system.pa /etc/pulse/tx5dr-system.pa

EXPOSE 4713

HEALTHCHECK --interval=2s --timeout=2s --start-period=5s --retries=20 \
  CMD PULSE_SERVER=tcp:127.0.0.1:4713 pactl info >/dev/null 2>&1 \
    && PULSE_SERVER=tcp:127.0.0.1:4713 pactl list short sinks | grep -q tx5dr_dummy_output

CMD ["pulseaudio", "--system", "--daemonize=no", "--disallow-exit", "--exit-idle-time=-1", "--disable-shm=true", "--log-target=stderr", "--log-level=notice", "--file=/etc/pulse/tx5dr-system.pa"]
