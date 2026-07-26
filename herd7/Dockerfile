# herd7 (herdtools7) memory-model checker for the SB litmus tests.
#
#   docker build -f herd7/Dockerfile -t lightepoch-herd7 herd7
#   docker run --rm lightepoch-herd7
#
# Builds herdtools7 from opam, then runs run.sh which checks each .litmus file
# against the architecture's official model and prints expected vs. observed.
FROM ocaml/opam:debian-12-ocaml-5.1

RUN sudo apt-get update && sudo apt-get install -y --no-install-recommends \
      libgmp-dev pkg-config m4 \
 && sudo rm -rf /var/lib/apt/lists/*

# herdtools7 provides herd7 / litmus7 / diy7.
RUN opam install -y herdtools7 \
 && sudo ln -sf "$(opam var bin)/herd7" /usr/local/bin/herd7

WORKDIR /litmus
COPY *.litmus run.sh ./
# Normalize line endings in case files were checked out with CRLF.
RUN sudo sed -i 's/\r$//' run.sh *.litmus && sudo chmod +x run.sh

ENTRYPOINT ["/bin/bash", "run.sh"]
