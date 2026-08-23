# Third-party notices

## TX-5DR

- Project: TX-5DR
- Source: https://github.com/boybook/tx-5dr
- Pinned commit: `f9e07fec6c5fb67b5c904936b5df03c1e3b0f5dc`
- License: GNU General Public License version 3 (`GPL-3.0`)
- Local modification: `deploy/tx5dr/patches/0001-mobile-six-digit-pairing.patch`

The deployment script downloads the corresponding source tree and leaves it at
`deploy/tx5dr/upstream/`, including TX-5DR's complete `LICENSE` file. The script
then applies the tracked patch in the working tree and verifies that no other
source differences are present before building the image.

## Hamlib

The dummy deployment installs the Debian `libhamlib-utils` package and runs the
Hamlib model 1 rigctld simulator. Hamlib license and copyright information is
provided by the Debian package in the resulting container image.

## PulseAudio

The dummy audio image installs Debian's PulseAudio packages and uses a null sink
for loopback testing. PulseAudio license and copyright information is provided
by the Debian packages in the resulting container image.
