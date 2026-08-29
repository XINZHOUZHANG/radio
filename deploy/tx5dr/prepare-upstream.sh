#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
UPSTREAM_DIR="$SCRIPT_DIR/upstream"
PATCH_FILE="$SCRIPT_DIR/patches/0001-mobile-six-digit-pairing.patch"
UPSTREAM_REPOSITORY=${TX5DR_UPSTREAM_REPOSITORY:-https://github.com/boybook/tx-5dr.git}
UPSTREAM_COMMIT=${TX5DR_UPSTREAM_COMMIT:-f9e07fec6c5fb67b5c904936b5df03c1e3b0f5dc}

case "$SCRIPT_DIR" in
  /opt/testradio|/opt/testradio/*) ;;
  *)
    echo "Refusing to prepare outside /opt/testradio: $SCRIPT_DIR" >&2
    exit 2
    ;;
esac

if [ ! -f "$PATCH_FILE" ]; then
  echo "Required TX-5DR patch is missing: $PATCH_FILE" >&2
  exit 3
fi

verify_expected_patch_state() {
  actual_commit=$(git -C "$UPSTREAM_DIR" rev-parse HEAD)
  if [ "$actual_commit" != "$UPSTREAM_COMMIT" ]; then
    return 1
  fi

  if [ -n "$(git -C "$UPSTREAM_DIR" ls-files --others --exclude-standard)" ]; then
    return 1
  fi

  verify_index=$(mktemp "$SCRIPT_DIR/.tx5dr-index.XXXXXX")
  rm -f "$verify_index"
  trap 'rm -f "$verify_index"' EXIT HUP INT TERM

  if ! GIT_INDEX_FILE="$verify_index" git -C "$UPSTREAM_DIR" read-tree "$UPSTREAM_COMMIT"; then
    return 1
  fi
  if ! GIT_INDEX_FILE="$verify_index" git -C "$UPSTREAM_DIR" apply --cached "$PATCH_FILE"; then
    return 1
  fi
  if GIT_INDEX_FILE="$verify_index" git -C "$UPSTREAM_DIR" diff --quiet --no-ext-diff; then
    verified=0
  else
    verified=$?
  fi

  rm -f "$verify_index"
  trap - EXIT HUP INT TERM
  return "$verified"
}

if [ ! -d "$UPSTREAM_DIR/.git" ]; then
  if [ -e "$UPSTREAM_DIR" ]; then
    echo "Refusing to replace non-git path: $UPSTREAM_DIR" >&2
    exit 4
  fi
  git clone --filter=blob:none --no-checkout "$UPSTREAM_REPOSITORY" "$UPSTREAM_DIR"
fi

ACTUAL_ORIGIN=$(git -C "$UPSTREAM_DIR" remote get-url origin)
if [ "$ACTUAL_ORIGIN" != "$UPSTREAM_REPOSITORY" ]; then
  echo "Unexpected TX-5DR origin: $ACTUAL_ORIGIN" >&2
  exit 5
fi

git -C "$UPSTREAM_DIR" fetch --depth=1 origin "$UPSTREAM_COMMIT"

if [ -n "$(git -C "$UPSTREAM_DIR" status --porcelain)" ]; then
  if ! verify_expected_patch_state; then
    echo "Refusing unexpected TX-5DR source changes in $UPSTREAM_DIR" >&2
    exit 6
  fi
  echo "Expected mobile pairing patch is already applied"
else
  git -C "$UPSTREAM_DIR" checkout --detach "$UPSTREAM_COMMIT"
  git -C "$UPSTREAM_DIR" apply --check "$PATCH_FILE"
  git -C "$UPSTREAM_DIR" apply "$PATCH_FILE"
fi

ACTUAL_COMMIT=$(git -C "$UPSTREAM_DIR" rev-parse HEAD)
if [ "$ACTUAL_COMMIT" != "$UPSTREAM_COMMIT" ]; then
  echo "TX-5DR commit verification failed: $ACTUAL_COMMIT" >&2
  exit 7
fi

if ! verify_expected_patch_state; then
  echo "TX-5DR mobile pairing patch verification failed" >&2
  exit 8
fi

echo "TX-5DR source pinned at $ACTUAL_COMMIT with the verified mobile pairing patch"
