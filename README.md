# RoamRun install and launch (Bitrise Step)

A Bitrise Step that installs an `.ipa` on your iPhone or iPad and launches it, from a build, over
Tailscale, with [roamrunctl](https://github.com/mh-mobile/RoamRun/tree/main/Rust/roamrunctl). The
device stays where it is (at home, at the office); the build reaches it through your tailnet.

The Step joins the tailnet itself: Bitrise has no Tailscale Step. It runs Tailscale in userspace (no
root, nothing changed on the build machine's network) and gives roamrunctl Tailscale's HTTP proxy
into the tailnet (`ROAMRUNCTL_PROXY`, roamrunctl 0.10.0 or later). Then it does one of two things,
as [RoamRun's CI guide](https://github.com/mh-mobile/RoamRun/blob/main/docs/ci.md) describes them:

- **`roamrun_key`**: roamrunctl runs on the build machine, with the device's pairing from a Secret.
  Nothing of yours runs while the build does.
- **`relay_address`**: a machine of yours runs `roamrunctl mcp --http` and keeps the device's key;
  the build sends it the `.ipa`, and the relay installs and launches.

macOS stacks with macOS 15 or later only (Xcode 16.3 or later): Homebrew's Tailscale has no
ready-built package for older macOS.

## Usage

After Xcode Archive & Export, with the key on the build machine:

```yaml
- xcode-archive@6:
    inputs:
      - distribution_method: development
- git::https://github.com/mh-mobile/bitrise-step-roamrun.git@1.0.0:
    inputs:
      - tailscale_auth_key: $TS_AUTHKEY
      - roamrun_key: $ROAMRUN_KEY
```

Through a relay:

```yaml
- git::https://github.com/mh-mobile/bitrise-step-roamrun.git@1.0.0:
    inputs:
      - tailscale_auth_key: $TS_AUTHKEY
      - relay_address: 100.x.y.z:9090
      - relay_token: $RELAY_TOKEN
      - device_name: phone
```

`TS_AUTHKEY`, `ROAMRUN_KEY` and `RELAY_TOKEN` are Bitrise Secrets: these inputs take Secrets only.
The relay's address and the device's name needn't be: Bitrise hides every occurrence of a Secret's
value in the log, so a name such as `relay` kept as a Secret turns roamrunctl's messages into
`[REDACTED]`. `ipa_path` defaults to `$BITRISE_IPA_PATH`, which Xcode Archive & Export sets when it
runs before this Step.

## What to prepare

- **The `.ipa`**, signed with a development (or ad hoc) profile that lists the device: the device in
  your team's device list, and code signing set up on Bitrise for Xcode Archive & Export.
- **A Tailscale auth key** (admin console › Settings › Keys): Reusable, Ephemeral, a tag such as
  `tag:ci` (your policy's `tagOwners` has to allow it), and a short expiry. The build's machine
  leaves the tailnet when the Step ends.
- **Your tailnet's policy** lets that tag reach, with `relay_address`, the relay's one port; with
  `roamrun_key`, the device on TCP: its pairing port (one of 49152–49167) and a tunnel port the device
  names anew each time, with no range known, so in effect any TCP port.
- **The key or the relay**, as the CI guide sets them up: `roamrun key create` on a Mac with RoamRun
  (or `roamrunctl pair control`), the whole file pasted into a Secret; or a relay running roamrunctl
  0.9.0 or later with `--allow tag:ci`, a token and `--allow-install <device>`.
- **The device**: on Wi‑Fi, and unlocked once since it started.

One device takes one install at a time: they aren't coordinated, and a relay refuses a second one
while the first runs. Keep builds that install on one device from running at the same time.

## Who can operate the device

Whoever can start a build, or push to a branch that builds, can read the Secrets (a Script Step can
print any of them), and so can see and operate the device:

- the key: until its name is removed from the device's Developer Mode list (Settings › Privacy &
  Security › Developer Mode);
- the relay's token: while the relay runs; restart it with a new token to take it back;
- the auth key: until it is revoked in the admin console or expires.

Bitrise gives a pull request's build no Secrets unless they are exposed to pull requests; then the
Step stops and says so. Exposing them gives whoever can open a pull request the same.

## Inputs

| Input | |
|---|---|
| `tailscale_auth_key` | The auth key, a Secret. Required. |
| `roamrun_key` | The device's pairing, a Secret: a file `roamrun key create` wrote, or one `roamrunctl pair control` saved. Give this or `relay_address`. |
| `relay_address` | The relay's address and port, as `roamrunctl mcp --http` printed them. Give this or `roamrun_key`. |
| `relay_token` | With `relay_address`, the relay's token, a Secret. |
| `device_name` | With `relay_address`, the device as the relay names it (required). With `roamrun_key`, the name it is saved under on the build machine (default `device`). |
| `ipa_path` | The `.ipa` to install. Default `$BITRISE_IPA_PATH`. Empty, and only `bundle_id` is launched. |
| `bundle_id` | The app to launch. Empty, and the app the `.ipa` holds is launched. |
| `launch_app` | `no` to install only. Default `yes`. (The GitHub Action's `launch` is `true` / `false`.) |
| `install_timeout` | With `relay_address`, the most seconds to wait for the install. By default, what the relay gives the upload and the install, and a minute more. |
| `roamrunctl_version` | The roamrunctl release to download. Default `0.10.0`; 0.10.0 or later. |
| `roamrunctl_path` | A roamrunctl to use instead of downloading one, such as a build not released yet. |

## What it does

1. Checks the inputs and the machine, and stops with a message before anything is downloaded or
   started.
2. Downloads roamrunctl for the machine from RoamRun's release, checks it against the release's
   `roamrunctl-SHA256SUMS`, and unpacks it into a folder of its own under `/tmp`.
3. `brew install tailscale`, then `tailscaled --tun=userspace-networking
   --outbound-http-proxy-listen=127.0.0.1:0` with its state in that folder, and `tailscale up` with the
   auth key from a file there (not on the command line), as `bitrise-<build number>`, without
   Tailscale's DNS. roamrunctl gets the proxy's port as `ROAMRUNCTL_PROXY`.
4. With `roamrun_key`: `roamrunctl key import -` reads the key from standard input into that folder.
   Then `roamrunctl install … --launch` (or `install`, or `launch`).
   With `relay_address`: `roamrunctl install … --relay <relay> --launch`.
5. Logs out of Tailscale, stops tailscaled and removes the folder, whether the Step passed or not.

Nothing is passed on to later Steps. A Step that Bitrise stops for its timeout, or for no output, is
killed, and step 5 doesn't run: on bitrise.io the machine is discarded and the ephemeral node leaves
the tailnet by itself; with the Bitrise CLI on your own Mac, stop the `tailscaled` left running and
remove the `/tmp/rr.*` folder.

## What was tried

On 2026-10-24 (UTC), on bitrise.io (Hobby plan; stack Xcode 27.1, machine M2 Pro Medium), with this
Step at its first commit on `main` and roamrunctl 0.10.0 built from RoamRun's `release/0.10.0`
(given as `roamrunctl_path`: 0.10.0 wasn't released yet), from a private repository, on an iPhone
15 Pro (iOS 27.0) at home, unlocked; the auth key Reusable, Ephemeral, `tag:ci`; a development-signed
`.ipa` of a template app:

| Workflow | Result |
|---|---|
| `roamrun_key` (a file `roamrun key create` wrote), an `.ipa` signed on a Mac and committed | installed and launched; the Step took 26 s |
| `relay_address` (a MacBook Pro, Homebrew roamrunctl 0.9.0) and the same `.ipa` | installed (5 s) and launched; the Step took 16 s |
| Xcode Archive & Export (`distribution_method: development`, signing by an App Store Connect API key and the development certificate), then `roamrun_key` with the default `ipa_path` | installed and launched; the Step took 21 s |

Each time, Homebrew poured Tailscale 1.104.1's ready-built package, the machine joined as
`bitrise-<build number>`, and it wasn't in the tailnet's machines afterwards. A look at the device
showed the app in front.

Not tried: the default download of roamrunctl (it waits for 0.10.0's release), `bundle_id`,
`launch_app: no`, `install_timeout`, an Intel Mac, the Bitrise CLI on a Mac of your own, a Step
stopped by its timeout, an iPad, a larger `.ipa`.

## License

MIT
