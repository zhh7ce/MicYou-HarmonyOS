---
name: Bug report
about: Something does not work as documented
labels: bug
---

**Describe the bug**
What happens, and what you expected instead.

**Environment**
- Phone model and system version (`hilog` prints both; e.g. HUAWEI nova 14 Pro, OpenHarmony 6.1.1.120, API 24)
- App version (`AppScope/app.json5` `versionName`)
- Desktop server: GUI or `micyou-cli serve`, and its version
- Connection settings in use: host/port, sample rate, channels, bit depth, capture source

**Steps to reproduce**
1. ...
2. ...

**Logs**
Start the app, then capture the engine tags and paste the relevant lines (technical
messages stay in English by design):

```bash
hdc shell "hilog -x -T MicYouEngine"
hdc shell "hilog -x -T MicYouControl"
hdc shell "hilog -x -T MicYouCapture"
```

Redact anything you do not want to publish. Do not paste your full `hilog` buffer — a
few dozen lines around the failure is enough.

**Desktop side**
Does the desktop show the session at all (device listed, packet counters moving)? If
audio arrives but sounds wrong, note whether it is choppy, too fast, too slow, or noise.
