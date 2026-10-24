#!/usr/bin/env bash
# Joins the tailnet (Tailscale in userspace; roamrunctl goes through its HTTP proxy), then installs and
# launches with roamrunctl: here (roamrun_key) or through a relay (relay_address).
set -euo pipefail

fail() { echo "error: $1" >&2; exit 1; }

auth_key=${tailscale_auth_key:-} key=${roamrun_key:-} relay=${relay_address:-} token=${relay_token:-}
device=${device_name:-} ipa=${ipa_path:-} bundle=${bundle_id:-} launch=${launch_app:-yes}
install_timeout=${install_timeout:-} version=${roamrunctl_version:-0.10.0} given_rr=${roamrunctl_path:-}

# A pull request's build gets no Secrets unless they are exposed to it: say so, not just "missing".
withheld() {
  if [ "${PR:-}" = true ]; then fail "$1 is empty: this is a pull request's build, and Bitrise gives those no Secrets unless they are exposed to pull requests"; fi
  fail "$1 is empty"
}

# What was asked, checked before anything is fetched or started.
[ -n "$auth_key" ] || withheld "tailscale_auth_key"
if [ -n "$key" ] && [ -n "$relay" ]; then fail "give roamrun_key or relay_address, not both"; fi
if [ -z "$key" ] && [ -z "$relay" ]; then withheld "roamrun_key (or relay_address with relay_token)"; fi
if [ -n "$relay" ] && [ -z "$token" ]; then withheld "relay_token"; fi
if [ -n "$relay" ] && [ -z "$device" ]; then fail "relay_address needs device_name: the device as the relay names it"; fi
if [ -z "$ipa" ] && [ -z "$bundle" ]; then fail "give ipa_path (to install) or bundle_id (to launch); \$BITRISE_IPA_PATH is set by Xcode Archive & Export when it runs before this Step"; fi
if [ -n "$ipa" ] && [ ! -f "$ipa" ]; then fail "no file at ipa_path: $ipa"; fi
case "$launch" in yes|no) ;; *) fail "launch_app is yes or no, not $launch" ;; esac
case "$install_timeout" in *[!0-9]*) fail "install_timeout is a number of seconds, not $install_timeout" ;; esac
if [ -n "$given_rr" ] && [ ! -x "$given_rr" ]; then fail "no program at roamrunctl_path: $given_rr"; fi

# Homebrew's tailscale has bottles for macOS 15 and later only; before that it would build from source.
[ "$(uname -s)" = Darwin ] || fail "this Step runs on macOS stacks only"
macos=$(sw_vers -productVersion)
[ "${macos%%.*}" -ge 15 ] || fail "macOS $macos: this Step needs a stack with macOS 15 or later (Xcode 16.3 or later)"
case "$(uname -m)" in
  arm64) archive=roamrunctl-macos-aarch64 ;;
  x86_64) archive=roamrunctl-macos-x86_64 ;;
  *) fail "no roamrunctl for $(uname -m)" ;;
esac
[ -z "$ipa" ] || ipa=$(cd "$(dirname "$ipa")" && pwd)/$(basename "$ipa")

# Everything this writes, the keys among them, is in a folder of its own, removed at the end. Short: a
# unix socket's path must stay under 104 bytes. (A timeout kills this with SIGKILL: then nothing is.)
work=$(mktemp -d /tmp/rr.XXXXXX)
daemon=
cleanup() {
  if [ -n "$daemon" ]; then
    "$bin/tailscale" --socket="$work/sock" logout > /dev/null 2>&1 &
    out=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$out" 2>/dev/null || break; sleep 1; done
    kill "$out" "$daemon" 2>/dev/null || true
    wait "$daemon" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
umask 077

if [ -n "$given_rr" ]; then
  rr=$given_rr
else
  echo "Fetching roamrunctl $version"
  base="https://github.com/mh-mobile/RoamRun/releases/download/v$version"
  curl -fsSL --retry 3 -o "$work/$archive.tar.gz" "$base/$archive.tar.gz"
  curl -fsSL --retry 3 -o "$work/SHA256SUMS" "$base/roamrunctl-SHA256SUMS"
  grep " $archive.tar.gz\$" "$work/SHA256SUMS" > "$work/want" || fail "$archive.tar.gz isn't in roamrunctl-SHA256SUMS of v$version"
  (cd "$work" && shasum -a 256 -c want)
  tar -xzf "$work/$archive.tar.gz" -C "$work" --strip-components 1 "$archive/roamrunctl"
  rr=$work/roamrunctl
fi
have=$("$rr" --version)
echo "$have"
# ROAMRUNCTL_PROXY came in 0.10.0: an older one would ignore it and fail to connect.
v=${have##* } && major=${v%%.*} && minor=${v#*.} && minor=${minor%%.*}
[ "$major" -gt 0 ] || [ "$minor" -ge 10 ] || fail "$have: this Step needs roamrunctl 0.10.0 or later"

echo "Installing Tailscale (Homebrew)"
HOMEBREW_NO_AUTO_UPDATE=1 brew install tailscale
bin=$(brew --prefix)/bin
"$bin/tailscale" version | head -1

echo "Starting tailscaled (userspace networking, an HTTP proxy into the tailnet)"
"$bin/tailscaled" --tun=userspace-networking --socket="$work/sock" --statedir="$work/state" \
  --outbound-http-proxy-listen=127.0.0.1:0 > "$work/log" 2>&1 &
daemon=$!
port=
for _ in $(seq 30); do
  kill -0 "$daemon" 2>/dev/null || { cat "$work/log" >&2; fail "tailscaled stopped"; }
  port=$(sed -n 's/.*HTTP proxy listening on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$work/log" | head -1)
  [ -S "$work/sock" ] && [ -n "$port" ] && break
  sleep 1
done
[ -n "$port" ] || { cat "$work/log" >&2; fail "tailscaled didn't start its proxy in 30 s"; }

host="bitrise-${BITRISE_BUILD_NUMBER:-local}"
echo "Joining the tailnet as $host"
printf '%s' "$auth_key" > "$work/authkey"
"$bin/tailscale" --socket="$work/sock" up --auth-key="file:$work/authkey" --hostname="$host" \
  --accept-dns=false --timeout=120s
rm -f "$work/authkey"
export ROAMRUNCTL_PROXY="http://127.0.0.1:$port"

# The options each command takes, written out: bash 3.2 (macOS's) refuses an empty array under set -u.
if [ -n "$key" ]; then
  export XDG_CONFIG_HOME="$work/config"
  name=${device:-device}
  printf '%s' "$key" | "$rr" key import - --as "$name"
  do_install() { "$rr" install "$name" "$ipa" "$@"; }
  do_launch() { "$rr" launch "$name" "$bundle"; }
else
  export ROAMRUNCTL_TOKEN="$token"
  name=$device
  do_install() {
    if [ -n "$install_timeout" ]; then "$rr" install "$name" "$ipa" --relay "$relay" --timeout "$install_timeout" "$@"
    else "$rr" install "$name" "$ipa" --relay "$relay" "$@"; fi
  }
  do_launch() { "$rr" launch "$name" "$bundle" --relay "$relay"; }
fi

if [ -n "$ipa" ]; then
  if [ "$launch" = yes ] && [ -z "$bundle" ]; then do_install --launch; else do_install; fi
fi
if [ -n "$bundle" ] && { [ -z "$ipa" ] || [ "$launch" = yes ]; }; then do_launch; fi
