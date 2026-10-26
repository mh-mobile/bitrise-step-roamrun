# RoamRun install and launch (Bitrise Step)

A Bitrise Step that installs an `.ipa` on your iPhone or iPad and launches it, from a build, over
Tailscale, with [roamrunctl](https://github.com/mh-mobile/RoamRun/tree/main/Rust/roamrunctl). The
device stays where it is (at home, at the office); the build reaches it through your tailnet.

The Step joins the tailnet itself (Bitrise's Step Library had no Tailscale Step when this was
written). It installs Tailscale with Homebrew, runs it in userspace (no root, nothing changed in the
build machine's network settings) and gives roamrunctl Tailscale's HTTP proxy into the tailnet
(`ROAMRUNCTL_PROXY`, roamrunctl 0.10.0 or later). Then it does one of two things, as
[RoamRun's CI guide](https://github.com/mh-mobile/RoamRun/blob/main/docs/ci.md) describes them:

- **`roamrun_key`**: roamrunctl runs on the build machine, with the device's pairing from a Secret.
  Nothing of yours runs while the build does.
- **`relay_address`**: a machine of yours runs `roamrunctl mcp --http` and keeps the device's key;
  the build sends it the `.ipa`, and the relay installs and launches.

It runs on macOS stacks with macOS 15 or later only: Homebrew's Tailscale had ready-built packages
for macOS 15 and later when this was written, and the Step stops on an older macOS (Bitrise's stack
reports list each stack's macOS; the stacks with Xcode 16.3 and later had macOS 15 or later).

## Usage

The Step isn't in Bitrise's Step Library: add it in `bitrise.yml` (the Workflow Editor's YAML view),
by its git URL and tag. After Xcode Archive & Export, with the key on the build machine:

```yaml
- xcode-archive@6:
    inputs:
      - distribution_method: development
      - automatic_code_signing: api-key
- git::https://github.com/mh-mobile/bitrise-step-roamrun.git@1.1.0:
    inputs:
      - tailscale_auth_key: $TS_AUTHKEY
      - roamrun_key: $ROAMRUN_KEY
```

Through a relay, after the same Xcode Archive & Export:

```yaml
- git::https://github.com/mh-mobile/bitrise-step-roamrun.git@1.1.0:
    inputs:
      - tailscale_auth_key: $TS_AUTHKEY
      - relay_address: 100.x.y.z:9090
      - relay_token: $RELAY_TOKEN
      - device_name: phone
```

`ipa_path` defaults to `$BITRISE_IPA_PATH`, which Xcode Archive & Export sets when it runs before
this Step.

## What to prepare

- **The device**: an iPhone or iPad with iOS/iPadOS 27 or later, Developer Mode on, Tailscale on it
  and signed in to your tailnet, on Wi‑Fi (a device on cellular alone doesn't accept these
  connections), and unlocked once since it started.
- **The `.ipa`**, signed with a development profile that lists the device (ad hoc wasn't tried): the device in
  your team's device list, and code signing set up on Bitrise for Xcode Archive & Export. The runs
  below used an App Store Connect API key (a paid Apple Developer Program team) and the Apple
  Development certificate; [RoamRun's Bitrise page](https://github.com/mh-mobile/RoamRun/blob/main/docs/bitrise.md)
  (from RoamRun 0.10.0) says where each goes.
- **A Tailscale auth key** (admin console › Settings › Keys; an OAuth client wasn't tried): Reusable,
  Ephemeral, a tag such as `tag:ci`, and a short expiry (90 days at most; when it has expired,
  `tailscale up` fails and the Step with it: make a new one). Your policy's `tagOwners` has to name
  the tag: [the CI guide](https://github.com/mh-mobile/RoamRun/blob/main/docs/ci.md#tailscale-a-tag-and-an-oauth-client)
  shows the lines (its OAuth client is for GitHub Actions; here the auth key takes its place).
- **Your tailnet's policy**: one that allows everything needs nothing more; the runs below used
  one. A narrowed one has to let the tag reach, with `relay_address`, the relay's one port; with
  `roamrun_key`, the device on TCP: its pairing port (one of 49152–49167) and a tunnel port the
  device names anew each time, with no range known, so in effect any TCP port. A narrowed policy
  wasn't tried.
- **The device's key** (for `roamrun_key`), made once beside the device; after that, nothing of it
  needs to run:
  - on a Mac with [RoamRun](https://github.com/mh-mobile/RoamRun) that the device is paired with:
    `roamrun key create <device> key.json --as ci`;
  - or on any machine on the device's Wi‑Fi with
    [roamrunctl](https://github.com/mh-mobile/RoamRun/tree/main/Rust/roamrunctl#install):
    `roamrunctl pair control --to <the device's Tailscale name> --as ci`, which saves it where
    roamrunctl keeps devices (`~/.config/roamrunctl/devices/` on macOS and Linux).

  Either asks you to pick the name under Settings › Privacy & Security › Developer Mode on the
  device and enter the code shown. [The CI guide](https://github.com/mh-mobile/RoamRun/blob/main/docs/ci.md#a-pairing-for-ci)
  has the details.
- **Or a relay** (for `relay_address`): roamrunctl 0.9.0 or later on a machine of yours, running
  `roamrunctl mcp --http <port> --allow tag:ci --token-file <file> --allow-install <device>`, as
  [the CI guide](https://github.com/mh-mobile/RoamRun/blob/main/docs/ci.md#on-the-relay) sets it up.
- **Bitrise Secrets** (the app's Workflow Editor › Secrets, "Expose for Pull Requests" off):
  `TS_AUTHKEY`, and `ROAMRUN_KEY` (the key file pasted whole) or `RELAY_TOKEN`. These inputs take
  Secrets only. The relay's address and the device's name needn't be Secrets: Bitrise hides every
  occurrence of a Secret's value in the log, and in the runs below a device named `relay`, kept as
  a Secret, put `[REDACTED]` into roamrunctl's messages wherever the word appeared.

One device takes one install at a time: they aren't coordinated, and a relay refuses a second one
while the first runs. Keep builds that install on one device from running at the same time (the
Hobby plan used below allows one concurrent build, by its Plan & Billing page; other ways weren't
looked into).

## Who can operate the device

Whoever can start a build, or push to a branch that builds, can read the Secrets (a Script Step can
print any of them):

- the auth key joins your tailnet as the tag, and reaches whatever your policy lets the tag reach
  (with a policy that allows everything, every machine of yours), until it is revoked in the admin
  console or expires;
- with the device's key, they can see and operate the device until its entry is removed from the
  device's Developer Mode list (the `--as` name for `roamrun key create`; for `roamrunctl pair
  control`, the Tailscale name of the machine that made it);
- with the relay's token, they can use the relay's tools on the device while the relay runs; stop
  it, or restart it with a new token, to take that back.

Bitrise gives a pull request's build no Secrets unless they are exposed to pull requests; with them
empty, the Step stops and says so. Exposing them gives whoever can open a pull request the same, and each
pull request's build joins your tailnet.

## Inputs

| Input | |
|---|---|
| `tailscale_auth_key` | The auth key, a Secret. Required. |
| `roamrun_key` | The device's pairing, a Secret: a file `roamrun key create` wrote, or one `roamrunctl pair control` saved. Give this or `relay_address`. |
| `relay_address` | The relay's address and port, as `roamrunctl mcp --http` printed them. Give this or `roamrun_key`. |
| `relay_token` | With `relay_address`, the relay's token, a Secret (required). |
| `device_name` | With `relay_address`, the device as the relay names it (required). With `roamrun_key`, any name for it on the build machine (default `device`). |
| `ipa_path` | The `.ipa` to install. Default `$BITRISE_IPA_PATH`. Leave it empty to launch `bundle_id` without installing. |
| `bundle_id` | The app to launch. Leave it empty to launch the app the `.ipa` holds. |
| `launch_app` | `no` to install without launching. Default `yes`. (With no `.ipa`, `bundle_id` is launched whatever this says.) |
| `install_timeout` | With `relay_address`, the most seconds to wait for the install. By default, what the relay gives the upload and the install, and a minute more. |
| `roamrunctl_version` | The roamrunctl release to download. Default `0.11.0`; 0.10.0 or later. |
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

Nothing is passed on to later Steps. If Bitrise stops the Step for its timeout or for no output,
the Bitrise CLI kills it, and step 5 doesn't run (not tried): on bitrise.io the machine is
discarded, and Tailscale removes an ephemeral machine some time after it goes offline; with the
Bitrise CLI on a Mac of your own, stop the `tailscaled` left running and remove the `/tmp/rr.*`
folder.

## What was tried

On 2026-10-24 (UTC), on bitrise.io (Hobby plan; stack Xcode 27.1, machine M2 Pro Medium), with this
Step at its first commit on `main` and roamrunctl 0.10.0 built from RoamRun's `release/0.10.0`
(given as `roamrunctl_path`: 0.10.0 wasn't released yet), from a private repository, on an iPhone
15 Pro (iOS 27.0) at home, unlocked; the auth key Reusable, Ephemeral, `tag:ci`, on a tailnet whose
policy allowed everything; a minimal SwiftUI app, development-signed:

| Workflow | Result |
|---|---|
| `roamrun_key` (a file `roamrun key create` wrote), an `.ipa` (21 KB) signed on a Mac and committed | installed and launched; the Step took 26 s |
| `relay_address` (a MacBook Pro, Homebrew roamrunctl 0.9.0), the same `.ipa` | installed (5 s) and launched; the Step took 16 s |
| Xcode Archive & Export (`distribution_method: development`, signing by an App Store Connect API key and the development certificate), then `roamrun_key` with the default `ipa_path` | installed and launched; the Step took 21 s |

Each time, Homebrew poured Tailscale 1.104.1's ready-built package and the machine joined as
`bitrise-<build number>`. After the first, the machine wasn't in the tailnet's machines, and a look
at the device showed the app in front.

The changes since that commit (among them the checks of `roamrunctl_version` and of tailscaled's
socket, the umask around brew, step.yml's wording and this README) ran through `scripts/check-refusals.sh` and the CI workflow, and
through `step.sh` with stand-ins for brew, Tailscale and roamrunctl; not on bitrise.io.

After roamrunctl 0.10.0's release, on 2026-10-24 (UTC), the `roamrun_key` workflow ran once more
with this Step's 1.0.0 and no `roamrunctl_path`: it downloaded roamrunctl 0.10.0 from the release,
checked it against `roamrunctl-SHA256SUMS`, and installed and launched the same `.ipa`; the Step took
27 s.

1.1.0 downloads roamrunctl 0.11.0 by default; that change ran through `scripts/check-refusals.sh`
and the CI workflow, not on bitrise.io. roamrunctl 0.11.0 itself installed and launched through a
relay from GitHub Actions, as the RoamRun docs say.

Not tried: a pull request's build, `bundle_id`, `launch_app: no`, `install_timeout`, an Intel Mac, the Bitrise CLI on a Mac of
your own, a Step stopped by its timeout, an iPad, a larger `.ipa`.

## License

MIT
