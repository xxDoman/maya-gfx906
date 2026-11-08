# maya-gfx906 — Maya dashboard on the Strata engine, built for AMD gfx906
#
#   docker build -f Dockerfile -t xxdoman/maya-gfx906:0.1 .
#   docker run -d --name maya --device /dev/kfd --device /dev/dri \
#       --group-add video --group-add render --ulimit memlock=-1 \
#       -p 8092:8092 -v /path/to/models:/models -v maya-data:/data \
#       xxdoman/maya-gfx906:0.1
#
# The engine is compiled inside the image from upstream source + patches/
# gfx906-deepseek4.patch. A binary built on the host does not travel: Ubuntu
# 26.04 links against glibc 2.43, the ROCm 24.04 base image has 2.39.
#
# Layout follows xxdoman/strata-mi50:
#   /opt/strata/engine/strata   engine (gfx906, deepseek4 pack path fixed)
#   /opt/maya/serve             Maya (upstream server, not a fork)
#   /opt/maya/defaults          configs copied to /data on the first start
#                               (strata-dsv4.json = 1 card, strata-dsv4-2x.json = 2 cards)
#   /models /data /work         volumes

ARG BASE=xxdoman/strata-mi50:0.2.9

FROM ${BASE} AS build
ENV DEBIAN_FRONTEND=noninteractive
ARG SRC_REPO=https://github.com/zephel01/Abyss
ARG SRC_COMMIT=c56e6d1   # upstream v1.3.116

RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake make g++ gcc git libgomp1 \
        hip-dev hipblas-dev rocblas-dev rocm-device-libs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY patches/ /patches/
RUN git clone --filter=blob:none ${SRC_REPO} /src \
    && git -C /src checkout ${SRC_COMMIT} \
    && git -C /src apply /patches/gfx906-deepseek4.patch

RUN cmake -S /src -B /src/build-gfx906 \
        -DCMAKE_BUILD_TYPE=Release \
        -DSTRATA_ENABLE_HIP=ON \
        -DSTRATA_ENABLE_CUDA=OFF \
        -DCMAKE_HIP_ARCHITECTURES=gfx906 \
        -DSTRATA_HIP_WMMA=0 \
        -DSTRATA_HIPCC=/opt/rocm/bin/hipcc \
        -DSTRATA_BUILD_TESTS=OFF \
        -DSTRATA_PORTABLE=ON \
        -DSTRATA_PREFILL_MMQ=ON \
        -DSTRATA_NATIVE_EXPERTS=ON \
        -DCMAKE_PREFIX_PATH=/opt/rocm \
    && cmake --build /src/build-gfx906 --target strata -j"$(nproc)" \
    && strip /src/build-gfx906/strata


FROM ${BASE}

ENV DEBIAN_FRONTEND=noninteractive \
    LD_LIBRARY_PATH=/opt/rocm/lib \
    PYTHONPATH=/opt/maya:/opt/maya/tools \
    PYTHONUNBUFFERED=1

RUN python3 -m pip install --no-cache-dir --break-system-packages \
        numpy jinja2 regex pyyaml tqdm requests pillow psutil

COPY --from=build /src/build-gfx906/strata /opt/strata/engine/strata
COPY --from=build /src/serve /opt/maya/serve
COPY --from=build /src/tools/strata_tokenizer.py /opt/maya/tools/strata_tokenizer.py
COPY --from=build /src/tools/gguf_reader.py /opt/maya/tools/gguf_reader.py
COPY maya/config/strata-dsv4.json /opt/maya/defaults/strata-dsv4.json
COPY maya/config/strata-dsv4-2x.json /opt/maya/defaults/strata-dsv4-2x.json
COPY maya/docker-entrypoint.sh /opt/maya/docker-entrypoint.sh

RUN chmod +x /opt/strata/engine/strata /opt/maya/docker-entrypoint.sh

EXPOSE 8092
ENTRYPOINT ["/opt/maya/docker-entrypoint.sh"]
