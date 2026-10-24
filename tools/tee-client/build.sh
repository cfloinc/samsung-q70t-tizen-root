#!/bin/sh
# Build, sign and install the TEEC client on the TV.
# Requires: Tizen Studio CLI, a signing profile (see METHODOLOGY.md), and the
# TV reachable over sdb. Set TV_IP in your environment.
set -eu
TV_IP="${TV_IP:?set TV_IP to your TV}"
PROFILE="${PROFILE:-q70t}"
TIZEN="${TIZEN:-$HOME/tizen-studio/tools/ide/bin/tizen}"

rm -rf bin obj ted.tpk
dotnet build tee.csproj -c Release -o out
mkdir -p bin
cp out/tee.dll out/tee.runtimeconfig.json bin/
cp out/tee.deps.json ./tee.deps.json 2>/dev/null || true
zip -q -r tee.tpk tizen-manifest.xml bin tee.deps.json
"$TIZEN" package -t tpk -s "$PROFILE" -- "$PWD/tee.tpk"
"$TIZEN" install -s "$TV_IP:26101" -n tee.tpk
echo "installed; launch with: aul_test launch <appid>"
