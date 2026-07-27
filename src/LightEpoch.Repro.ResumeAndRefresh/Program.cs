using LightEpoch.Repro.Common;

namespace LightEpoch.Repro.ResumeAndRefresh
{
    internal static class Program
    {
        static int Main(string[] args) => ReproRunner.Run<ResumeAndRefreshReproPattern>(args);
    }
}
