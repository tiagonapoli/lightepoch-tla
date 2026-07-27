using LightEpoch.Repro.Common;

namespace LightEpoch.Repro.Garnet
{
    internal static class Program
    {
        static int Main(string[] args)
            => ReproRunner.Run<GarnetBasicContextReproPattern>(args);
    }
}
