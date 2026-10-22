#!/usr/bin/env bash
# Usage: ./repro.sh <release|dev|pr|inline> [runs] [command|page-load]
# Builds the app against the chosen wry, installs it on $ANDROID_SERIAL and cold-starts it
# `runs` times. `command` calls the sync command `read_url` from the page, and `page-load`
# also calls `webview.url()` from Tauri's `on_page_load`. Each run prints its log lines.
set -euo pipefail
variant=${1:?release, dev, pr or inline}
runs=${2:-3}
mode=${3:-command}
cd "$(dirname "$0")"
: "${ANDROID_SERIAL:?set ANDROID_SERIAL to the emulator or device serial}"
export ANDROID_SERIAL
app=com.example.wryipcthreadrepro
pr_rev=0c95f9a3577c4e5b9e9b6fc6ea69597dd772d272

case "$variant" in
  release | dev) marker='webViewClient.currentUrl' ;;
  pr) marker='dispatcher.execute' ;;
  inline) marker='webView.url ?: "about:blank"' ;;
  *) echo "unknown variant $variant" >&2; exit 1 ;;
esac
case "$mode" in
  command) features=() ;;
  page-load) features=(--features page-load) ;;
  *) echo "unknown mode $mode" >&2; exit 1 ;;
esac

if [ "$variant" = inline ] && [ ! -d .wry-inline ]; then
  git init -q .wry-inline
  git -C .wry-inline fetch -q --depth 1 https://github.com/LucaCappelletti94/wry "$pr_rev"
  git -C .wry-inline checkout -q FETCH_HEAD
  git -C .wry-inline apply ../variants/inline.patch
fi

mkdir -p .cargo
cp "variants/$variant.toml" .cargo/config.toml
if [ -z "${SKIP_BUILD:-}" ]; then
  [ -d gen/android ] || cargo tauri android init
  export CARGO_TARGET_DIR="target/$variant-$mode"
  cargo tauri android build --debug --apk -t "${TARGET:-x86_64}" "${features[@]}" >&2
  # Catches a stale generated Ipc.kt from another variant.
  if ! grep -qF "$marker" gen/android/app/src/main/java/com/example/wryipcthreadrepro/generated/Ipc.kt; then
    echo "generated Ipc.kt does not match $variant" >&2
    exit 1
  fi
  adb install -r gen/android/app/build/outputs/apk/universal/debug/app-universal-debug.apk >/dev/null
fi

returned=0 crashed=0
for i in $(seq 1 "$runs"); do
  adb shell am force-stop "$app"
  since="$(adb shell date +%s | tr -d '\r').000"
  adb shell am start -W -n "$app/.MainActivity" >/dev/null
  pid=$(adb shell pidof "$app" | tr -d '\r')
  outcome="no result within 30s"
  log=""
  for _ in $(seq 1 60); do
    log=$(adb logcat -d -v time -T "$since" -s RustStdoutStderr:I | grep -E "\( *$pid\): .*(REPRO|panicked at|Result::unwrap)" || true)
    if grep -qE 'REPRO [a-z_]+ returned' <<<"$log"; then
      # The crash follows the return within milliseconds.
      sleep 2
      log=$(adb logcat -d -v time -T "$since" -s RustStdoutStderr:I | grep -E "\( *$pid\): .*(REPRO|panicked at|Result::unwrap)" || true)
      break
    fi
    sleep 0.5
  done
  if grep -q 'Result::unwrap' <<<"$log"; then
    outcome=crashed; crashed=$((crashed + 1))
  elif grep -qE 'REPRO [a-z_]+ returned' <<<"$log"; then
    outcome=returned; returned=$((returned + 1))
  fi
  echo "run $i: $outcome"
  sed -E 's/ I\/RustStdoutStderr\( *[0-9]+\): / /; s/^/  /' <<<"$log"
done
adb shell am force-stop "$app"
echo "$variant $mode: $returned returned normally, $crashed crashed, $((runs - returned - crashed)) no result"
