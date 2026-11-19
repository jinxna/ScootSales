#!/usr/bin/env bash
set -euo pipefail

usage="usage: scripts/ci_lanes.sh LANES FLOW[,FLOW...]"
lanes="${1:?${usage}}"
flows="${2:?${usage}}"
case "${lanes}" in
  [1-9]) ;;
  *) echo "LANES must be a number from 1 to 9, got ${lanes}" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
out="${root}/e2e/output"
user="$(id -un)"
mkdir -p "${out}"

mapfile -t lane_flows < <(LANES="${lanes}" FLOWS="${flows}" node -e '
const times = require("./e2e/flow_times.json");
const lanes = Number(process.env.LANES);
const names = process.env.FLOWS.split(",").map((n) => n.trim());
if (names.length < lanes) throw new Error("fewer flows than lanes");
const seconds = (n) => {
  if (!Object.hasOwn(times, n)) throw new Error("no recorded time for " + n);
  return times[n];
};
const buckets = Array.from({ length: lanes }, () => ({ s: 0, f: [] }));
for (const n of [...names].sort((a, b) => seconds(b) - seconds(a) || a.localeCompare(b))) {
  const lightest = buckets.reduce((best, b) => (b.s < best.s ? b : best));
  lightest.s += seconds(n);
  lightest.f.push(n);
}
for (const b of buckets) console.log(b.f.join(","));
')

echo "Download the Firestore emulator before any lane has its own network"
npx --no-install firebase setup:emulators:firestore

sdk_ready() {
  compgen -G "${root}/e2e/.cache/firebase-*/package/firebase-app.js" > /dev/null
}

wait_for_sdk() {
  local lane1_pid="$1" waited=0
  until sdk_ready; do
    kill -0 "${lane1_pid}" 2>/dev/null || { echo "lane 1 stopped before the Firebase web SDK was packed" >&2; return 1; }
    [ "${waited}" -lt 300 ] || { echo "the Firebase web SDK was not packed within 300 s" >&2; return 1; }
    sleep 2
    waited=$((waited + 2))
  done
  echo "Firebase web SDK packed by lane 1 after ${waited} s"
}

run_lane() {
  local k="$1" list="$2" lane_tmp
  lane_tmp="$(mktemp -d)"
  local -a lane_env=("E2E_FLOWS=${list}" "E2E_OUTPUT_TAG=lane${k}" "TMPDIR=${lane_tmp}" "PATH=${PATH}" "HOME=${HOME}")
  if [ "${k}" = "1" ]; then
    env "${lane_env[@]}" npm run e2e
  else
    sudo unshare --net -- bash -c 'ip link set lo up && ip link add lane0 type dummy && ip addr add 10.213.0.1/24 dev lane0 && ip link set lane0 up && ip route add default dev lane0 && exec sudo -u "$0" env "$@"' \
      "${user}" "${lane_env[@]}" npm run e2e
  fi
}

pids=()
start_ms="$(date +%s%3N)"
for ((k = 1; k <= lanes; k++)); do
  echo "lane ${k}: ${lane_flows[k-1]}"
  run_lane "${k}" "${lane_flows[k-1]}" > "${out}/lane${k}.log" 2>&1 &
  pids+=("$!")
  if [ "${k}" = "1" ] && [ "${lanes}" -gt 1 ]; then
    wait_for_sdk "${pids[0]}"
  fi
done

trap 'kill "${pids[@]}" 2>/dev/null || true' INT TERM

failed=0
exits=""
for ((k = 1; k <= lanes; k++)); do
  status=0
  wait "${pids[k-1]}" || status=$?
  [ "${status}" -eq 0 ] || failed=1
  exits="${exits}${exits:+,}\"${k}\":${status}"
done
end_ms="$(date +%s%3N)"

wall="$(awk -v a="${start_ms}" -v b="${end_ms}" 'BEGIN { printf "%.1f", (b - a) / 1000 }')"
printf '{"lanes":%s,"wallSeconds":%s,"laneExit":{%s}}\n' "${lanes}" "${wall}" "${exits}" > "${out}/wall.json"
cat "${out}/wall.json"
exit "${failed}"
