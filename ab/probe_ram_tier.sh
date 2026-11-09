#!/bin/bash
# Sonda: czy tier RAM 40 GB wstaje, i co realnie trzyma pamiec w trakcie pinowania.
# Uzycie: probe_ram_tier.sh <GB> [sekund]
set -u
GB="${1:-40}"
LIMIT="${2:-300}"
IMG=xxdoman/maya-gfx906:0.2-mxfp4.1
NAME=maya-probe
cd "$(dirname "$0")"

python3 - "$GB" <<'PY'
import json, sys, subprocess
gb = sys.argv[1]
IMG = "xxdoman/maya-gfx906:0.2-mxfp4.1"
out = subprocess.run(f"docker run --rm -v maya-data:/data --entrypoint cat {IMG} /data/maya/strata-dsv4.json",
                     shell=True, capture_output=True, text=True).stdout
cfg = json.loads(out)
cfg.setdefault("env", {})["STRATA_GLM_RAM_GB"] = gb
cfg["env"].pop("STRATA_DS4_DSPARK", None)
cfg["env"].pop("STRATA_DS4_DSPARK_EXPERTS", None)
args = [a for a in cfg["args"] if a not in ("--spec", "4", "5")]
cfg["args"] = args + ["--spec", "4"]
open("_probe.json", "w").write(json.dumps(cfg, indent=2))
subprocess.run(f"docker run --rm -v maya-data:/data -v $PWD:/ab --entrypoint cp {IMG} /ab/_probe.json /data/maya/strata-dsv4.json", shell=True, check=True)
print("[probe] tier:", gb, "GB | args:", " ".join(cfg["args"]))
PY

docker rm -f "$NAME" >/dev/null 2>&1
sleep 3
docker run --rm -v maya-data:/data --entrypoint sh "$IMG" -c \
  'cd /data/maya/logs && [ -f abyss-server.log ] && mv -f abyss-server.log abyss-server.log.prev; true' >/dev/null 2>&1

docker run -d --name "$NAME" --device /dev/kfd --device /dev/dri \
  --group-add video --group-add render --ulimit memlock=-1 -v /home/models:/models \
  -v maya-data:/data "$IMG" >/dev/null

echo "czas  strata_RSS  CPU%  stan  MemUsed MemCached MemAvail  ostatnia_linia_logu"
t0=$(date +%s)
while :; do
  el=$(( $(date +%s) - t0 ))
  [ "$el" -gt "$LIMIT" ] && { echo "[probe] limit ${LIMIT}s — przerywam"; break; }
  read -r rss cpu stat < <(docker exec "$NAME" ps -o rss=,pcpu=,stat= -C strata 2>/dev/null | awk '{printf "%s %s %s", int($1/1024), $2, $3}')
  mem=$(awk '/^MemTotal|^MemFree|^MemAvailable|^Cached:/ {printf "%s ", int($2/1024)}' /proc/meminfo)
  last=$(docker exec "$NAME" tail -1 /data/maya/logs/abyss-server.log 2>/dev/null | cut -c1-60)
  printf "%4ss %7sMB %5s%% %4s  %s %s\n" "$el" "${rss:-?}" "${cpu:-?}" "${stat:-?}" "$mem" "$last"
  if docker exec "$NAME" grep -q "glm5-next serve" /data/maya/logs/abyss-server.log 2>/dev/null; then
    echo "[probe] SILNIK WSTAL po ${el}s"
    echo "--- co silnik trzyma (log) ---"
    docker exec "$NAME" grep -E "RAM tier|expert pool|held pinned" /data/maya/logs/abyss-server.log | sed 's/^/  /'
    echo "--- proces strata ---"
    docker exec "$NAME" sh -c 'P=$(pgrep -x strata); ps -o rss=,vsz= -p $P | awk "{printf \"  RSS %d MB  VSZ %d MB\n\", \$1/1024, \$2/1024}"; grep -E "Rss|Pss|Private|Shared|Anonymous|Swap" /proc/$P/smaps_rollup | sed "s/^/  /"'
    echo "--- /proc/meminfo ---"
    grep -E "^(MemTotal|MemFree|MemAvailable|Cached|Buffers|SReclaimable|SwapTotal|SwapFree|Mlocked|Unevictable):" /proc/meminfo | sed 's/^/  /'
    echo "--- cgroup kontenera ---"
    docker exec "$NAME" sh -c 'cat /sys/fs/cgroup/memory.current 2>/dev/null | awk "{printf \"  memory.current %.1f GB\n\", \$1/1073741824}"; cat /sys/fs/cgroup/memory.max 2>/dev/null | sed "s/^/  memory.max /"'
    break
  fi
  sleep 15
done
docker rm -f "$NAME" >/dev/null 2>&1
echo "[probe] koniec"
