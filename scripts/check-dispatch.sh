#!/usr/bin/env bash
# What step.sh runs in each mode, through stand-ins for brew, Tailscale and roamrunctl (given as
# roamrunctl_path, so curl isn't called): each roamrunctl call, with the token and proxy it saw, and no
# /tmp/rr.* folder left. macOS's /bin/bash (3.2), as on Bitrise.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fake=$(mktemp -d)
failed=0
mkdir -p "$fake/prefix/bin" "$fake/ipa"
touch "$fake/ipa/app.ipa"
ipa=$(cd "$fake/ipa" && pwd)/app.ipa
printf '#!/bin/sh\necho "curl was called" >&2; exit 99\n' > "$fake/curl"
cat > "$fake/brew" <<END
#!/bin/sh
case "\$1" in install) ;; --prefix) echo "$fake/prefix" ;; *) exit 99 ;; esac
END
cat > "$fake/uname" <<'END'
#!/bin/sh
case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac
END
printf '#!/bin/sh\necho 15.7.9\n' > "$fake/sw_vers"
printf '#!/bin/sh\nexit 0\n' > "$fake/prefix/bin/tailscale"
# A unix socket at --socket, and the proxy's line, as tailscaled gives them.
cat > "$fake/prefix/bin/tailscaled" <<'END'
#!/bin/sh
for a in "$@"; do case "$a" in --socket=*) sock=${a#--socket=} ;; esac; done
echo "HTTP proxy listening on 127.0.0.1:1056"
exec nc -lU "$sock"
END
cat > "$fake/roamrunctl" <<END
#!/bin/sh
[ "\$1" = --version ] && { echo "roamrunctl 0.12.0"; exit 0; }
[ "\$1" = key ] && cat > /dev/null
echo "\$* | token=\${ROAMRUNCTL_TOKEN-none} proxy=\${ROAMRUNCTL_PROXY-none}" >> "$fake/calls"
END
chmod +x "$fake"/* "$fake/prefix/bin"/*
before=$(find /tmp/ -maxdepth 1 -name 'rr.*' | wc -l)

# $1: the calls wanted, one a line; then the inputs.
expect() {
  local want=$1; shift
  rm -f "$fake/calls"
  local out
  out=$(env -i PATH="$fake:$PATH" tailscale_auth_key=tskey-test roamrun_key= relay_address= relay_token= \
    device_name= ipa_path= bundle_id= launch_app=yes install_timeout= roamrunctl_version=0.12.0 \
    roamrunctl_path="$fake/roamrunctl" ota_server= ota_server_token= replace=no "$@" /bin/bash "$here/step.sh" 2>&1)
  local status=$? got
  got=$(cat "$fake/calls" 2>/dev/null)
  if [ "$status" -eq 0 ] && [ "$got" = "$want" ]; then echo "ok: $want"
  else echo "FAIL ($status): wanted"; echo "$want"; echo "got"; echo "$got"; echo "$out"; failed=1; fi
}

proxy="proxy=http://127.0.0.1:1056"
expect "ota $ipa --server 100.64.0.2:9091 | token=ota-secret $proxy" \
  ota_server=100.64.0.2:9091 ota_server_token=ota-secret ipa_path="$fake/ipa/app.ipa" launch_app=maybe
expect "ota $ipa --server 100.64.0.2:9091 --replace --timeout 300 | token=ota-secret $proxy" \
  ota_server=100.64.0.2:9091 ota_server_token=ota-secret ipa_path="$fake/ipa/app.ipa" replace=yes install_timeout=300
expect "ota $ipa --server 100.64.0.2:9091 --timeout 300 | token=ota-secret $proxy" \
  ota_server=100.64.0.2:9091 ota_server_token=ota-secret ipa_path="$fake/ipa/app.ipa" install_timeout=300
# The other modes, as before.
expect "key import - --as device | token=none $proxy
install device $ipa --launch | token=none $proxy" roamrun_key=k ipa_path="$fake/ipa/app.ipa"
expect "install phone $ipa --relay 100.64.0.1:9090 --launch | token=relay-secret $proxy" \
  relay_address=100.64.0.1:9090 relay_token=relay-secret device_name=phone ipa_path="$fake/ipa/app.ipa"

if [ "$(find /tmp/ -maxdepth 1 -name 'rr.*' | wc -l)" != "$before" ]; then echo "FAIL: a /tmp/rr.* folder was left"; failed=1; fi
rm -rf "$fake"
exit "$failed"
