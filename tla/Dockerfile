# TLC model checker for every TLA+ spec in this repo.
#
# Build:
#   docker build -f tla/Dockerfile -t lightepoch-tla tla
# Run all specs (memory-model litmus + the four LightEpoch reclamation specs):
#   docker run --rm lightepoch-tla

FROM eclipse-temurin:21-jre

ADD https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar /opt/tla2tools.jar

WORKDIR /work
COPY . .
RUN sed -i 's/\r$//' run.sh && chmod +x run.sh

ENTRYPOINT ["bash", "run.sh"]
