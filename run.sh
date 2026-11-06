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
set -e
docker run -d --name maya \
  --device /dev/kfd --device /dev/dri \
  --group-add video --group-add render \
  --ulimit memlock=-1 \
  -p 8092:8092 \
  -v /home/models:/models \
  -v maya-data:/data \
  xxdoman/maya-gfx906:0.1
echo "dashboard: http://127.0.0.1:8092/"
echo "config:    wolumen maya-data -> /data/maya/strata-dsv4.json"
