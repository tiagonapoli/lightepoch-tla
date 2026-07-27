using LightEpoch.Repro.Common;

namespace LightEpoch.Repro.Bare
{
    internal static class Program
    {
        static int Main(string[] args) => ReproRunner.Run<BareReproPattern>(args);
    }
}
