#!/usr/bin/env bash
# Each wrong input, and each machine it can't run on, stops step.sh with its message before anything is
# fetched or started (curl and brew here fail if called).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
temp=$(mktemp -d)
fake=$(mktemp -d)
failed=0
printf '#!/bin/sh\necho "curl was called" >&2; exit 99\n' > "$fake/curl"
printf '#!/bin/sh\necho "brew was called" >&2; exit 99\n' > "$fake/brew"
cat > "$fake/uname" <<'END'
#!/bin/sh
case "$1" in -s) echo "${FAKE_OS:-Darwin}" ;; -m) echo "${FAKE_ARCH:-arm64}" ;; esac
END
cat > "$fake/sw_vers" <<'END'
#!/bin/sh
echo "${FAKE_MACOS:-15.7.9}"
END
chmod +x "$fake"/*
touch "$fake/app.ipa"

expect() {
  local want=$1; shift
  local got
  got=$(cd "$temp" && env -i PATH="$fake:$PATH" tailscale_auth_key=tskey-test roamrun_key= relay_address= \
    relay_token= device_name= ipa_path= bundle_id= launch_app=yes install_timeout= roamrunctl_version=0.10.0 \
    roamrunctl_path= "$@" bash "$here/step.sh" 2>&1)
  local status=$?
  if [ "$status" -ne 0 ] && [ "$got" = "error: $want" ]; then echo "ok: $want"
  else echo "FAIL: wanted 'error: $want' and a failure, got ($status): $got"; failed=1; fi
}

expect "tailscale_auth_key is empty" tailscale_auth_key= roamrun_key=k bundle_id=b
expect "tailscale_auth_key is empty: this is a pull request's build, and Bitrise gives those no Secrets unless they are exposed to pull requests" tailscale_auth_key= PR=true roamrun_key=k bundle_id=b
expect "roamrun_key (or relay_address with relay_token) is empty" bundle_id=b
expect "give roamrun_key or relay_address, not both" roamrun_key=k relay_address=r bundle_id=b
expect "relay_token is empty: this is a pull request's build, and Bitrise gives those no Secrets unless they are exposed to pull requests" PR=true relay_address=100.64.0.1:9090 device_name=d bundle_id=b
expect "relay_address needs device_name: the device as the relay names it" relay_address=100.64.0.1:9090 relay_token=t bundle_id=b
expect "give ipa_path (to install) or bundle_id (to launch); \$BITRISE_IPA_PATH is set by Xcode Archive & Export when it runs before this Step" roamrun_key=k
expect "no file at ipa_path: missing.ipa" roamrun_key=k ipa_path=missing.ipa
expect "launch_app is yes or no, not true" roamrun_key=k bundle_id=b launch_app=true
expect "install_timeout is a number of seconds, not 5m" relay_address=r relay_token=t device_name=d bundle_id=b install_timeout=5m
expect "no program at roamrunctl_path: /nonexistent/roamrunctl" roamrun_key=k bundle_id=b roamrunctl_path=/nonexistent/roamrunctl
expect "this Step runs on macOS stacks only" roamrun_key=k bundle_id=b FAKE_OS=Linux
expect "macOS 14.5: this Step needs a stack with macOS 15 or later (Xcode 16.3 or later)" roamrun_key=k ipa_path="$fake/app.ipa" FAKE_MACOS=14.5
expect "no roamrunctl for i386" roamrun_key=k bundle_id=b FAKE_ARCH=i386

if [ -n "$(ls -A "$temp")" ]; then echo "FAIL: something was written: $(ls -A "$temp")"; failed=1; fi
rm -rf "$temp" "$fake"
exit "$failed"
