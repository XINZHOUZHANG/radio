# Third-party notices

Radio Lite uses the following third-party components. Their licenses and
copyright notices remain with the corresponding source or installed package.

## Hamlib

Radio Lite invokes the system-provided `rigctld` and `rigctl` utilities for
radio discovery and control. Hamlib is installed separately on the Debian host;
its package supplies the applicable license and copyright information.

## wsjtx-lib

- Package: `wsjtx-lib` version `2.1.3`
- Source: https://github.com/boybook/wsjtx-lib-nodejs
- License: GNU General Public License version 3 (`GPL-3.0`)

The server pins this package exactly and runs its native FT8/FT4 encoder and
decoder in an isolated child process. The installed package includes its full
`LICENSE` file.

## ws

- Package: `ws` version `8.21.3`
- Source: https://github.com/websockets/ws
- License: MIT

The server pins this package exactly for its WebSocket transport. The installed
package retains its license metadata.

## Debian audio utilities

Real audio capture, playback and Opus transport use separately installed ALSA,
PulseAudio and `opus-tools` utilities. Their Debian packages provide the
applicable license and copyright information.
