# Rig-control safety

The control plane defaults to receive/control-only operation for existing or
locally launched hardware. Automated tests exercise PTT only against the bundled
`MockRigctld`; they do not prove that a real radio, feed line, antenna, tuner, or
load is safe.

## PTT admission and trips

PTT-on is admitted only when all of these are true:

- the supervisor has a current READY session;
- the caller holds the exact current lease and its heartbeat is fresh;
- the effective TX frequency is known and within the current session's
  discovered TX ranges (the authoritative split enablement, TX VFO, frequency,
  and mode must all be readable; split TX frequency is used when enabled);
- the three-second post-fault lockout has expired; and
- hardware TX has been explicitly enabled when the endpoint is not the mock.

The safety supervisor de-keys and revokes authority on owner disconnect,
transport fault, shutdown, SWR at or above 3.0, heartbeat age over 10 seconds, or
continuous transmission reaching 180 seconds. PTT-off is an emergency-priority
operation and does not require a valid lease. After a failed connection, the
runtime reconciles a newly connected session to PTT-off and confirms readable
PTT state before publishing READY. A failed de-key remains latched for retry.
Telemetry polling and the time-based watchdog run independently, so a failed
meter or state read cannot suppress heartbeat or hard-limit de-key. An SWR trip
remains latched until a fresh reading is at or below the reset threshold.

Discovery absence, provider failure, malformed TX ranges, unknown effective TX
frequency, and non-READY lifecycle all fail closed. Lease identifiers and raw
CAT payloads are excluded from safe errors and trip audit metadata.

## Explicit hardware TX opt-in

Real/existing/local-launch modes remain TX-disabled unless **both** flags are
present:

```text
--enable-hardware-tx --acknowledge-transmit-risk
```

Either flag alone is rejected before a listener, connection, serial device, or
subprocess starts. These flags are operator acknowledgement, not a safety
certification. Do not enable them merely to make a test pass.

## FT-710 operator acceptance with a dummy load

Real FT-710 transmission is deliberately outside automated acceptance. A
qualified operator should complete a controlled acceptance session before any
on-air use:

1. Disconnect antennas and connect a correctly rated 50-ohm dummy load.
2. Verify the FT-710 model ID, COM device, baud rate, region/band limits, mode,
   RF power, and cooling.
3. Disable amplifiers, external tuners, automatic antenna switching, and other
   unintended RF paths.
4. Confirm receive-only discovery and snapshot values first.
5. Confirm that the displayed effective TX frequency is legal and inside the
   discovered TX range.
6. Use the lowest practical power and a short manual transmission while watching
   an independent wattmeter and SWR indication.
7. Verify lease-heartbeat, client-disconnect, SWR, hard-limit, transport-fault,
   and shutdown de-key behavior under operator supervision.
8. Stop immediately on unexpected RF, power, SWR, temperature, relay, or control
   behavior; investigate before retrying.

External-tuner sequencing, audio, FT8 automation, remote station authorization,
and iOS UI safeguards are future product work and are not covered by this
control-plane acceptance suite.
