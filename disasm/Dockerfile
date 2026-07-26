# Captures JIT-native disassembly of the epoch announce/reclaim methods.
# Build once, then run per target architecture (the emulated arm64 runtime still
# JITs real AArch64 machine code):
#
#   docker build -f disasm/Dockerfile -t lightepoch-disasm .
#   docker run --rm --platform linux/amd64 -v "$PWD/disasm/x86_64:/out" lightepoch-disasm
#   docker run --rm --platform linux/arm64 -v "$PWD/disasm/arm64:/out"  lightepoch-disasm
FROM mcr.microsoft.com/dotnet/sdk:8.0

WORKDIR /src
COPY src/LightEpoch.Implementations/ src/LightEpoch.Implementations/
COPY disasm/tool/ disasm/tool/
RUN dotnet publish disasm/tool/DisasmDump.csproj -c Release -o /app

COPY disasm/capture.sh /app/capture.sh
RUN sed -i 's/\r$//' /app/capture.sh && chmod +x /app/capture.sh

WORKDIR /app
ENTRYPOINT ["/bin/bash", "/app/capture.sh"]
