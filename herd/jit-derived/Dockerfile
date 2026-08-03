# herd7 memory-model checks for the CAS-carries-the-announce LightEpoch fix.
#
# Build (from the repository root):
#   docker build -t lightepoch-herd herd/jit-derived
# Run every litmus test:
#   docker run --rm lightepoch-herd
# Run a subset:
#   docker run --rm lightepoch-herd arm64-refresh
#
# Exits non-zero if any result does not match its expectation.

FROM ocaml/opam:debian-12-ocaml-4.14

RUN sudo apt-get update \
 && sudo apt-get install -y --no-install-recommends m4 \
 && sudo rm -rf /var/lib/apt/lists/*

RUN opam install -y herdtools7

WORKDIR /work
COPY . .
RUN sudo sed -i 's/\r$//' run.sh && sudo chmod +x run.sh

ENTRYPOINT ["opam", "exec", "--", "bash", "run.sh"]
