# TX-5DR server deployment

This deployment uses the official `boybook/tx-5dr` source at commit
`f9e07fec6c5fb67b5c904936b5df03c1e3b0f5dc`. The source is fetched into this
directory only when `prepare-upstream.sh` runs on the Debian host. The script
refuses to operate outside `/opt/testradio` and refuses to overwrite a dirty
upstream checkout.

## Dummy acceptance server

```sh
cd /opt/testradio/deploy/tx5dr
cp .env.example .env
chmod +x prepare-upstream.sh start-dummy.sh
./start-dummy.sh
```

The stack binds every externally used port on `0.0.0.0`:

- `8076/tcp`: HTTP web/API
- `8443/tcp`: HTTPS web/API
- `50110/udp`: rtc-data-audio
- `4532/tcp`: optional TX-5DR rigctld bridge

The `dummy-rig` container runs Hamlib model 1. The `dummy-audio` container runs
a 48 kHz mono PulseAudio null sink; its monitor source loops TX-5DR output back
into TX-5DR input. Both services are reachable only inside the private Compose
network. PulseAudio port 4713 is deliberately **not** published on the host.

`configure-dummy.mjs` logs in with the generated admin token inside the TX-5DR
container and performs an idempotent bootstrap. It:

- chooses the live PulseAudio input/output returned by `/api/audio/devices`;
- configures Hamlib at `dummy-rig:4532` and connects it;
- selects FT8 and creates `N0CALL / AA00` only when no operator exists;
- starts the engine and requires audio, radio, and decoding state to become live;
- starts TX-5DR's external rigctld bridge on `0.0.0.0:4532` in read-only mode;
- pulses CAT PTT for 500 ms and invokes the dummy tuner's manual tune operation.

The script never prints the admin token or JWT. A successful run prints only a
small device/status report. Change the dummy identity in `.env` if desired:

```dotenv
TX5DR_DUMMY_CALLSIGN=N0CALL
TX5DR_DUMMY_GRID=AA00
```

To retrieve the initial administrator token for browser login, run this only in
your private terminal:

```sh
docker compose exec -T tx5dr sh -c 'cat /app/data/config/.admin-token'
```

After logging in, create a username/password account in TX-5DR settings. The
iOS app can then use that account or a single-use six-digit mobile pairing code.

## Acceptance checks

```sh
docker compose ps
docker compose logs --tail=120 dummy-audio tx5dr dummy-rig
docker compose exec -T tx5dr node /opt/testradio-bootstrap/configure-dummy.mjs
```

The last command is safe to repeat. It must report named audio devices,
`ptt: verified`, an FT8 engine state, and tuner capabilities. This is a simulated
RF environment: it validates TX-5DR's actual Hamlib, RtAudio, PTT, decoder and
tuner paths without accessing `/dev/snd`, USB, or a transmitter.

For a real radio, first stop transmitting and make a backup. Add only the exact
serial devices to `docker-compose.hardware.yml`, then start with both files:

```sh
docker compose -f docker-compose.yml -f docker-compose.hardware.yml up -d
```

Do not expose the HTTP port on the public internet. Use HTTPS and restrict
ingress with Tailscale, a firewall, or a trusted reverse proxy before any real
RF testing.
