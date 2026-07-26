```

BenchmarkDotNet v0.14.0, Ubuntu 24.04.4 LTS (Noble Numbat)
Unknown processor
.NET SDK 8.0.129
  [Host]     : .NET 8.0.29 (8.0.2926.32403), Arm64 RyuJIT AdvSIMD
  DefaultJob : .NET 8.0.29 (8.0.2926.32403), Arm64 RyuJIT AdvSIMD


```
| Method                     | Mean     | Error    | StdDev   | Ratio | Allocated | Alloc Ratio |
|--------------------------- |---------:|---------:|---------:|------:|----------:|------------:|
| &#39;baseline (no fence)&#39;      | 16.04 ns | 0.010 ns | 0.010 ns |  1.00 |         - |          NA |
| full-barrier               | 20.90 ns | 0.017 ns | 0.015 ns |  1.30 |         - |          NA |
| interlocked-exchange       | 22.98 ns | 0.021 ns | 0.018 ns |  1.43 |         - |          NA |
| &#39;asymmetric (reader side)&#39; | 16.08 ns | 0.014 ns | 0.013 ns |  1.00 |         - |          NA |
