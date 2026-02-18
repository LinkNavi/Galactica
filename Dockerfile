FROM archlinux:base AS builder

RUN pacman -Syu --noconfirm \
    base-devel curl libarchive openssl zstd go \
    libcrypt shadow

WORKDIR /galactica
COPY . .

RUN mkdir -p AirRide/Init/build && \
    g++ -o AirRide/Init/build/airride AirRide/Init/src/main.cpp \
    -std=c++17 -O2 -static-libgcc -static-libstdc++

RUN mkdir -p AirRide/Ctl/build && \
    g++ -o AirRide/Ctl/build/airridectl AirRide/Ctl/src/main.cpp \
    -std=c++17 -O2

RUN gcc -O2 -D_GNU_SOURCE -o Poyo/poyo Poyo/src/main.c -lcrypt

RUN mkdir -p Dreamland/build && \
    g++ -o Dreamland/build/dreamland Dreamland/src/main.cpp \
    -std=c++17 -O2 -fPIC \
    -lcurl -lssl -lcrypto -lz -lzstd -larchive -lpthread -ldl

FROM archlinux:base AS runtime

RUN pacman -Syu --noconfirm \
    busybox libcurl-gnutls libarchive openssl zstd \
    libcrypt shadow iproute2 iputils procps-ng util-linux

COPY --from=builder /galactica/AirRide/Init/build/airride  /sbin/airride
COPY --from=builder /galactica/AirRide/Ctl/build/airridectl /usr/bin/airridectl
COPY --from=builder /galactica/Poyo/poyo                    /sbin/poyo
COPY --from=builder /galactica/Dreamland/build/dreamland    /usr/bin/dreamland
COPY --from=builder /galactica/bootstrap.sh                 /bootstrap.sh

RUN ln -sf /usr/bin/dreamland /usr/bin/dl && \
    mkdir -p /etc/airride/services /var/log/airride /run /etc/hostname && \
    echo "galactica" > /etc/hostname && \
    chmod +x /bootstrap.sh

COPY docker/services/ /etc/airride/services/

CMD ["/bin/bash"]
