```

BenchmarkDotNet v0.14.0, Ubuntu 24.04.4 LTS (Noble Numbat)
Unknown processor
.NET SDK 8.0.129
  [Host]     : .NET 8.0.29 (8.0.2926.32403), Arm64 RyuJIT AdvSIMD
  DefaultJob : .NET 8.0.29 (8.0.2926.32403), Arm64 RyuJIT AdvSIMD


```
| Method                     | Mean     | Error     | StdDev    | Ratio | Allocated | Alloc Ratio |
|--------------------------- |---------:|----------:|----------:|------:|----------:|------------:|
| &#39;baseline (no fence)&#39;      | 6.013 ns | 0.0210 ns | 0.0186 ns |  1.00 |         - |          NA |
| full-barrier               | 7.844 ns | 0.0132 ns | 0.0123 ns |  1.30 |         - |          NA |
| interlocked-exchange       | 7.201 ns | 0.0084 ns | 0.0079 ns |  1.20 |         - |          NA |
| &#39;asymmetric (reader side)&#39; | 6.149 ns | 0.0044 ns | 0.0039 ns |  1.02 |         - |          NA |
