# Every check for the Bf-Tree CPR handshake bug in one image: Miri, stock GenMC
# (RC11) and RustMC.
#
# Build:
#   docker build -f bftree/Dockerfile -t bftree-cpr bftree
# Run all three tools:
#   docker run --rm bftree-cpr
# Run one:
#   docker run --rm bftree-cpr miri
#   docker run --rm bftree-cpr genmc
#   docker run --rm bftree-cpr rustmc
#
# `genmc/genmc` is the base rather than a copied binary because it is the only
# one of the three with the RC11 driver, and it arrives already matched to its
# LLVM 18. RustMC is built on top against LLVM 21.

FROM genmc/genmc

ENV DEBIAN_FRONTEND=noninteractive \
    RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    STOCK_GENMC=/root/genmc/RelWithDebInfo/genmc
ENV PATH=/opt/cargo/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git \
      autoconf automake libtool make pkg-config g++ \
      libffi-dev zlib1g-dev libedit-dev libxml2-dev \
 && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/trixie/ llvm-toolchain-trixie-21 main" \
      > /etc/apt/sources.list.d/llvm-21.list \
 && apt-get update && apt-get install -y --no-install-recommends \
      clang-21 llvm-21 llvm-21-dev llvm-21-tools \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain nightly -c miri \
 && rustup toolchain install nightly-2025-08-20 --profile minimal

# RustMC installs its own `genmc` to /usr/local/bin; the stock one stays at
# $STOCK_GENMC. They are not interchangeable -- see run.sh. The base image keeps
# a `genmc` directory at that name, which `install` refuses to overwrite.
ARG RUSTMC_COMMIT=6d576f858b
RUN rm -rf /usr/local/bin/genmc \
 && git clone https://github.com/Ollie-Pearce/rustmc.git /opt/rustmc \
 && cd /opt/rustmc \
 && git checkout "$RUSTMC_COMMIT" \
 && autoreconf --install \
 && ./configure --with-llvm=/usr/lib/llvm-21 \
 && make -j"$(nproc)" \
 && make install

WORKDIR /work
COPY . .

# Bake the Miri sysroot into the image so a run is checks only, not a
# first-time toolchain build. MIRI_SYSROOT points at it directly: the build
# lock that `cargo miri` uses to revalidate the cache does not survive into the
# image layer, and without it every run re-derives the sysroot from scratch.
RUN cargo +nightly miri setup && cargo +nightly build --bins --tests
ENV MIRI_SYSROOT=/root/.cache/miri

RUN sed -i 's/\r$//' run.sh && chmod +x run.sh

ENTRYPOINT ["bash", "run.sh"]
