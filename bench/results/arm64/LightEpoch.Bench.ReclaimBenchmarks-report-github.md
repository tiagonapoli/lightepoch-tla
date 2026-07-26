```

BenchmarkDotNet v0.14.0, Ubuntu 24.04.4 LTS (Noble Numbat)
Unknown processor
.NET SDK 8.0.129
  [Host]     : .NET 8.0.29 (8.0.2926.32403), Arm64 RyuJIT AdvSIMD
  DefaultJob : .NET 8.0.29 (8.0.2926.32403), Arm64 RyuJIT AdvSIMD


```
| Method                        | Mean     | Error   | StdDev  | Ratio | RatioSD | Allocated | Alloc Ratio |
|------------------------------ |---------:|--------:|--------:|------:|--------:|----------:|------------:|
| &#39;baseline (no fence)&#39;         | 131.0 ns | 0.49 ns | 0.45 ns |  1.00 |    0.00 |         - |          NA |
| full-barrier                  | 135.8 ns | 0.71 ns | 0.67 ns |  1.04 |    0.01 |         - |          NA |
| interlocked-exchange          | 141.7 ns | 0.95 ns | 0.84 ns |  1.08 |    0.01 |         - |          NA |
| &#39;asymmetric (reclaimer side)&#39; | 947.0 ns | 6.87 ns | 6.09 ns |  7.23 |    0.05 |         - |          NA |
