#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"

if [[ $(uname -m) == arm64 ]]; then
    brew=/opt/homebrew/bin/brew
else
    brew=/usr/local/bin/brew
fi
if [[ ! -x $brew ]]; then
    printf '請先從 https://brew.sh 安裝 Homebrew。\n' >&2
    exit 1
fi
for formula in whisper-cpp opencc; do
    if ! "$brew" list --versions "$formula" >/dev/null; then
        "$brew" install "$formula"
    fi
done

config="$HOME/.config/isay"
apps="$HOME/Applications"
mkdir -p "$config" "$apps"

installed="$apps/iSay.app"
identity=${ISAY_SIGNING_IDENTITY:-}
if [[ -z $identity ]]; then
    identity=$(security find-identity -v -p codesigning | awk '/"Apple Development: / { id = $2; n++ } END { if (n == 1) print id }')
fi
requirement=''
if [[ -d $installed ]]; then
    requirement=$(codesign -d -r- "$installed" 2>&1 | awk '/^designated => / { sub(/^designated => /, ""); print }')
fi
if [[ -z $identity && -n $requirement && $requirement != cdhash\ * ]]; then
    printf '找不到 iSay 的開發簽署憑證。請用 ISAY_SIGNING_IDENTITY 指定原本的身分，再更新。\n' >&2
    exit 1
fi

fetch_model() {
    local file="$config/$1" url="$2" checksum="$3"
    if [[ -f $file ]] && printf '%s  %s\n' "$checksum" "$file" | shasum -a 256 -c --status; then
        return
    fi
    curl --fail --location --retry 2 --output "$file.part" "$url"
    printf '%s  %s\n' "$checksum" "$file.part" | shasum -a 256 -c --status
    mv -f -- "$file.part" "$file"
}

fetch_model ggml-large-v3-turbo-q5_0.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin \
    394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2
fetch_model ggml-silero-v6.2.0.bin \
    https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin \
    2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987

build=$(mktemp -d)
trap 'rm -r -- "$build"' EXIT
bundle="$build/iSay.app"
mkdir -p "$bundle/Contents/MacOS"
cp Info.plist "$bundle/Contents/Info.plist"
xcrun swiftc -O -swift-version 6 -target "$(uname -m)-apple-macosx14.0" Sources/*.swift -o "$bundle/Contents/MacOS/iSay"
whisper_prefix=$("$brew" --prefix whisper-cpp)
ggml_prefix=$("$brew" --prefix ggml)
xcrun clang -O2 -Wall -Wextra -Werror Tools/isay-prompt.c \
    -I"$ggml_prefix/include" -I"$whisper_prefix/include" -L"$whisper_prefix/lib" -L"$ggml_prefix/lib" \
    -Wl,-rpath,"$whisper_prefix/lib" -Wl,-rpath,"$ggml_prefix/lib" -lwhisper -lggml \
    -o "$bundle/Contents/MacOS/isay-prompt"
codesign --force --sign "${identity:--}" "$bundle/Contents/MacOS/isay-prompt"
codesign --force --sign "${identity:--}" "$bundle"
codesign --verify --strict "$bundle"
if [[ -n $requirement && $requirement != cdhash\ * ]] && ! codesign --verify -R="$requirement" "$bundle"; then
    printf '新版簽署身分跟已安裝的 iSay 不符；保留原版，避免權限失效。\n' >&2
    exit 1
fi
ditto "$bundle" "$installed"
printf '已安裝：%s\n' "$installed"
