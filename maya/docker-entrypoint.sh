#!/bin/sh
# maya-gfx906 — entrypoint w stylu strata-mi50.
#
# Co robi:
#   1. Config lezy na wolumenie /data/maya/strata-dsv4.json.
#      Przy pierwszym starcie kopiuje sie z /opt/maya/defaults/ — pozniej
#      przezywa `docker rm`, aktualizacje obrazu i restart hosta.
#      Ktory plik domyslny: DEFAULT_CONFIG=strata-dsv4-2x.json dla dwoch kart.
#   2. Modele: /models (zamapowany katalog). Nic nie jest wpieczone.
#   3. Serwer Mayi jest procesem glownym (PID 1), wiec `docker stop` dziala.
#   4. Argumenty podane po nazwie obrazu trafiaja do serve/server.py, wiec
#      `docker run ... xxdoman/maya-gfx906:0.1 --gpu 0,1` nie jest po cichu
#      wyrzucane.
#
# --ulimit memlock=-1 jest wymagane przy `docker run`: bez tego silnik nie
# zapnie tieru RAM ekspertow i zawiesi sie na mlock.
set -e

export MODELS_DIR="${MODELS_DIR:-/models}"
export DATA_DIR="${DATA_DIR:-/data}"
export CONFIG="${CONFIG:-${DATA_DIR}/maya/strata-dsv4.json}"
export PORT="${PORT:-8092}"
export DEFAULT_CONFIG="${DEFAULT_CONFIG:-strata-dsv4.json}"

mkdir -p "$(dirname "$CONFIG")" "$DATA_DIR/maya/logs"

if [ ! -f "$CONFIG" ]; then
    echo "[maya] brak configu — kopiuje /opt/maya/defaults/$DEFAULT_CONFIG do $CONFIG"
    cp "/opt/maya/defaults/$DEFAULT_CONFIG" "$CONFIG"
else
    echo "[maya] uzywam istniejacego configu: $CONFIG"
fi

export LD_LIBRARY_PATH=/opt/rocm/lib

# Ustawienie silnika przez `docker run -e NAZWA=wartosc`.
#
# Config ma wlasny blok "env", a serve/server.py naklada go NA srodowisko
# procesu: samo `-e STRATA_GLM_RAM_GB=96` bylo po cichu ignorowane, dopoki
# klucz siedzial w JSON-ie (a w domyslnym siedzi). Zmienna podana z zewnatrz
# jest wiec wpisywana do configu i mowimy o tym glosno.
patch_env() {
    python3 - "$CONFIG" "$1" "$2" <<'PY'
import json, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    cfg = json.load(f)
env = cfg.setdefault("env", {})
if str(env.get(key, "")) != val:
    env[key] = val
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print("[maya] env.%s -> %s w %s" % (key, val, path))
PY
}

for var in STRATA_GLM_RAM_GB STRATA_GLM_RAM_RESIDENT STRATA_GLM_TIMING STRATA_GLM_RAM_THP; do
    eval "val=\${$var:-}"
    if [ -n "$val" ]; then
        patch_env "$var" "$val"
    fi
done

RAM_TIER=$(python3 - "$CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
print((cfg.get("env") or {}).get("STRATA_GLM_RAM_GB", "?"))
PY
)

ML=$(ulimit -l)
echo "[maya] modele=${MODELS_DIR} dane=${DATA_DIR} memlock=${ML} RAM tier=${RAM_TIER} GB"
if [ "$ML" != "unlimited" ]; then
    if [ "$ML" -lt 8388608 ] 2>/dev/null; then
        echo "[maya] UWAGA: ulimit -l=${ML} kB — dodaj --ulimit memlock=-1 do docker run"
    fi
fi

echo "[maya] dashboard na :${PORT}"

if [ "${MAYA_DRY_RUN:-0}" = "1" ]; then
    echo "[maya] MAYA_DRY_RUN=1 — nie startuje serwera; config:"
    cat "$CONFIG"
    exit 0
fi

exec python3 /opt/maya/serve/server.py --engine strata \
     --config "$CONFIG" --port "$PORT" --host 0.0.0.0 "$@"
