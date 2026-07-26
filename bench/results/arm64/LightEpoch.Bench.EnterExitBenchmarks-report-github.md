```

BenchmarkDotNet v0.14.0, Ubuntu 24.04.4 LTS (Noble Numbat)
Unknown processor
.NET SDK 8.0.129
  [Host]     : .NET 8.0.29 (8.0.2926.32403), Arm64 RyuJIT AdvSIMD
  DefaultJob : .NET 8.0.29 (8.0.2926.32403), Arm64 RyuJIT AdvSIMD


```
| Method                     | Mean     | Error    | StdDev   | Ratio | Allocated | Alloc Ratio |
|--------------------------- |---------:|---------:|---------:|------:|----------:|------------:|
| &#39;baseline (no fence)&#39;      | 14.40 ns | 0.007 ns | 0.006 ns |  1.00 |         - |          NA |
| full-barrier               | 17.28 ns | 0.007 ns | 0.006 ns |  1.20 |         - |          NA |
| interlocked-exchange       | 17.49 ns | 0.022 ns | 0.019 ns |  1.21 |         - |          NA |
| &#39;asymmetric (reader side)&#39; | 14.51 ns | 0.026 ns | 0.025 ns |  1.01 |         - |          NA |
