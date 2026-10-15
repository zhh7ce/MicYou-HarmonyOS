# Contributing

Thanks for taking a look. This is a single-module HarmonyOS NEXT app written in strict
ArkTS plus one napi native module (`libmcyopus.so`, wrapping libopus), with no
third-party ArkTS/runtime dependencies, so the bar to get building is low.

## What this project is

A MicYou client for HarmonyOS phones: it captures the microphone and streams PCM —
or, on-device, Opus-encoded audio with out-of-band XOR FEC parity packets — to
a MicYou desktop server over the shared wire protocol. Upstream project (desktop server
plus Android and iOS clients): <https://github.com/MicYou-Dev/MicYou>.

The wire protocol is defined by
`tauri-app/crates/micyou-protocol/proto/network.proto` in the desktop repository. This
client hand-rolls the proto3 subset it needs under `entry/src/main/ets/net/` and does not
depend on a protobuf runtime.

## Getting set up

1. Install DevEco Studio (or the HarmonyOS Command Line Tools) plus the SDK. Everything
   below is driven from the CLI, so the IDE is only needed once, for signing.
2. Fetch the native dependency: libopus is a git submodule at `lib/opus` (pinned to
   v1.5.2, BSD-3), so before the first build run

   ```bash
   git submodule update --init
   ```

3. Export the SDK location; every `hvigorw` invocation fails without it:

   ```bash
   export DEVECO_SDK_HOME=/path/to/sdk
   ```

4. Copy the tracked profile template and let DevEco fill in the signing block
   (File > Project Structure > Project > Signing Configs > "Automatically generate
   signature"). `build-profile.json5` is gitignored on purpose — the encrypted key
   material it holds only decrypts on the machine that generated it. The module-level
   `entry/build-profile.json5` is tracked and already carries the `externalNativeOptions`
   block that builds `entry/src/main/cpp/`.

   ```bash
   cp build-profile.example.json5 build-profile.json5
   ```

5. Build:

   ```bash
   hvigorw assembleHap --no-daemon
   ```

   The installable output is `entry/build/default/outputs/default/entry-default-signed.hap`.
   With an empty `signingConfigs` array the build still succeeds but only produces an
   unsigned HAP, which a phone will refuse to install.

## Checking your change

There is no automated test suite. A change is verified by a clean build plus a manual run
on a real phone against a desktop server (`cargo run -p micyou-cli -- serve` in the
desktop repository is the quickest way to get one). Install, log and layout-dump commands
are in [AGENTS.md](AGENTS.md), section "Debug loop".

If you touch `net/Pb.ets` or any field number in `net/Messages.ets`, re-run the codec
against an independent protobuf parser (protobufjs in a scratch directory — it is not a
project dependency) and confirm the emitted bytes and the decoded values still round-trip.
The harness also round-trips the FEC parity packet (`[0x01]` marker, group-start
`fecSequenceNumber`, packed lengths) and asserts regular audio packets never carry FEC
fields; keep both checks green.

## Code style

- Strict ArkTS: no `any`, explicit types on every declaration including lambda
  parameters. The compiler is unforgiving about `| undefined` versus `| null`; this
  codebase null-checks with `=== null` on locals.
- Validate at the trust boundary (frame magic, payload length, datagram size, handshake
  bytes, resolved address) and keep the inside lean. A corrupt stream should fail the
  connection, not be guessed at.
- Never call `getContext()` and never cache a context inside a network or audio class.
  The ability context comes from `AppEnvironment`; transport objects take host and port
  strings only.
- All colors go through `$r('app.color.xxx')`, declared in both
  `resources/base/element/color.json` and `resources/dark/element/color.json`. No
  hardcoded hex in `.ets`.
- All user-facing strings go through `resources/{base,zh_CN,zh_TW}/element/string.json`.
  Adding one key means updating all three files. Technical error text and wire strings
  stay in English.
- Every `.ets` file opens with the license header: `SPDX-License-Identifier:
  GPL-3.0-or-later` followed by the standard GPL paragraphs and the copyright line.
- `hilog` format strings use `%{public}s` / `%{public}d`. A bare `%s` renders as
  `<private>` on a release device and silently loses the value you logged.

## Icons

The header mark, the start-window icon and the layered launcher icon are all drawn by
one script (Pillow is the only external requirement, and it is a dev tool, not a
dependency of the app):

```bash
python3 scripts/gen_logo.py
```

It writes six PNGs: `app_logo.png` and `startIcon.png` plus the
`foreground.png`/`background.png` pair under both `AppScope/resources/base/media/` and
`entry/src/main/resources/base/media/`. Edit the geometry constants at the top of the
script rather than hand-editing the images, and commit the regenerated PNGs with the
script change.

## Committing

- Branch from `master`, open a pull request against `master`.
- Commit messages are English, Conventional Commits style: `<type>: <description>`,
  for example `feat: stream the phone microphone to a desktop server`.
- Keep one logical change per commit, and separate code changes from documentation
  changes.
- Do not commit signing material, `build-profile.json5`, or anything under `build/`.

## Protocol changes

Anything that changes bytes on the wire has to be mirrored in the desktop server and in
the Android client, or the three clients diverge. Open an issue first so the field
numbers and semantics can be agreed before code is written.

## License

This project is licensed under the GNU General Public License version 3.0 or (at your
option) any later version. By submitting a pull request you confirm that you hold the
rights to the contribution and that it is offered under the same license, with no
additional permissions or restrictions. The native module links against libopus, which
is BSD-3 licensed and shipped as the `lib/opus` git submodule; its licence text is in
`lib/opus/COPYING`.
