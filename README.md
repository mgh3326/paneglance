# paneglance

`paneglance` is a macOS menu-bar app for a single console's fleet glance API. It
has no Dock icon when run from the bundled app. If its configuration file is
absent, it shows only `Not configured`.

## Configuration

Create `~/.config/paneglance/config.toml` on the machine that will run the app:

```toml
console_url   = "https://console.example"
cf_access_env = "~/.config/panewire/cf-access.env"
machine_id    = "machine-a"
launchd_label = "dev.panewire.panewired"
launchd_plist = "~/Library/LaunchAgents/dev.panewire.panewired.plist"
poll_seconds  = 30
```

The environment file supplies `CF_ACCESS_CLIENT_ID` and
`CF_ACCESS_CLIENT_SECRET`. Both values remain in memory and are sent only as
Cloudflare Access request headers.

## Build and test

```bash
swift build -c release
```

On a Mac that has CommandLineTools but not Xcode, run the committed wrapper so
Swift can find and load the Swift Testing framework:

```bash
bash scripts/test-local.sh
```

On a full Xcode installation, regular `swift test` works. Build an ad-hoc
signed application bundle with:

```bash
bash scripts/bundle.sh
```
