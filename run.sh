#!/bin/bash
# Uruchomienie maya-gfx906 — tak samo jak xxdoman/strata-mi50.
#
# Config NIE jest montowany: entrypoint kopiuje domyslny do wolumenu /data/maya
# przy pierwszym starcie i od tej pory korzysta z niego (przezywa restart
# kontenera, usuniecie kontenera i aktualizacje obrazu).
#
# Montaze bez :ro — silnik musi moc dopisac do /models cache ekspertow i plik
# tuningu rocBLAS. Read-only wywalaloby to na EACCES.
#
# --ulimit memlock=-1 jest obowiazkowe: bez niego silnik nie zapnie tieru RAM
# ekspertow i zawiesi sie na mlock.
#
# Dwie karty: obie przechodza przez /dev/dri, ale samo to nie wystarcza.
# ZMIERZONE na X99 + 2x MI50: bez -e ROCR_VISIBLE_DEVICES=0,1
# -e HIP_VISIBLE_DEVICES=0,1 (przy configu "gpu": "0,1" + "layer_split": "auto")
# silnik wypisuje "layer split across GPUs [0, 1] (auto)", po czym laduje tylko
# CUDA0: RAM skacze >90 GB, dekodowanie 19.5 -> 16.0 tok/s, trafienia ekspertow
# 89% -> 60%. Trzeba ustawic jedno I drugie.
# Gotowy config: -e DEFAULT_CONFIG=strata-dsv4-2x.json (tylko przy pierwszym
# starcie, potem /data/maya/strata-dsv4.json jest zrodlem prawdy).
set -e
docker run -d --name maya \
  --device /dev/kfd --device /dev/dri \
  --group-add video --group-add render \
  --ulimit memlock=-1 \
  -p 8092:8092 \
  -v /home/models:/models \
  -v maya-data:/data \
  xxdoman/maya-gfx906:0.2-mxfp4
echo "dashboard: http://127.0.0.1:8092/"
echo "config:    wolumen maya-data -> /data/maya/strata-dsv4.json"
