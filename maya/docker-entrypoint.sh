#!/bin/sh
# maya-gfx906 — entrypoint w stylu strata-mi50.
#
# Co robi:
#   1. Config lezy na wolumenie /data/maya/strata-dsv4.json.
#      Przy pierwszym starcie kopiuje sie z /opt/maya/defaults/ — pozniej
#      przezywa `docker rm`, aktualizacje obrazu i restart hosta.
#   2. Modele: /models (zamapowany katalog). Nic nie jest wpieczone.
#   3. Serwer Mayi jest procesem glownym (PID 1), wiec `docker stop` dziala.
#
# --ulimit memlock=-1 jest wymagane przy `docker run`: bez tego silnik nie
# zapnie tieru RAM ekspertow i zawiesi sie na mlock.
set -e

export MODELS_DIR="${MODELS_DIR:-/models}"
export DATA_DIR="${DATA_DIR:-/data}"
export CONFIG="${CONFIG:-${DATA_DIR}/maya/strata-dsv4.json}"
export PORT="${PORT:-8092}"

mkdir -p "$(dirname "$CONFIG")" /data/maya/logs

if [ ! -f "$CONFIG" ]; then
    echo "[maya] brak configu — kopiuje domyslny do $CONFIG"
    cp /opt/maya/defaults/strata-dsv4.json "$CONFIG"
else
    echo "[maya] uzywam istniejacego configu: $CONFIG"
fi

export LD_LIBRARY_PATH=/opt/rocm/lib
export STRATA_GLM_RAM_GB="${STRATA_GLM_RAM_GB:-32}"
export STRATA_GLM_RAM_THP="${STRATA_GLM_RAM_THP:-0}"
export STRATA_GLM_TIMING="${STRATA_GLM_TIMING:-1}"

echo "[maya] modele=${MODELS_DIR} dane=${DATA_DIR} memlock=$(ulimit -l) RAM tier=${STRATA_GLM_RAM_GB} GB"
echo "[maya] dashboard na :${PORT}"

exec python3 /opt/maya/serve/server.py --engine strata \
     --config "$CONFIG" --port "$PORT" --host 0.0.0.0
