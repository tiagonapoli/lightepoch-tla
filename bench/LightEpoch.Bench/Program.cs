using BenchmarkDotNet.Running;

namespace LightEpoch.Bench
{
    // Run all:   dotnet run -c Release -- --filter *
    // Enter/exit: dotnet run -c Release -- --filter *EnterExit*
    // Reclaim:    dotnet run -c Release -- --filter *Reclaim*
    internal static class Program
    {
        static void Main(string[] args) =>
            BenchmarkSwitcher.FromAssembly(typeof(Program).Assembly).Run(args);
    }
}
