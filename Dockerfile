FROM archlinux:base

RUN pacman -Syu --noconfirm base-devel curl libarchive openssl zstd go

COPY . /galactica
WORKDIR /galactica/Dreamland

RUN mkdir -p build && g++ -o build/dreamland src/main.cpp \
    -std=c++17 -O2 -fPIC \
    -lcurl -lssl -lcrypto -lz -lzstd -larchive -lpthread -ldl

ENV PATH="/galactica/Dreamland/build:$PATH"
WORKDIR /galactica

CMD ["bash"]
