```

BenchmarkDotNet v0.14.0, Windows 11 (10.0.26200.8893) (Hyper-V)
Unknown processor
.NET SDK 10.0.302
  [Host]     : .NET 8.0.29 (8.0.2926.32403), X64 RyuJIT AVX2
  DefaultJob : .NET 8.0.29 (8.0.2926.32403), X64 RyuJIT AVX2


```
| Method                        | Mean     | Error    | StdDev  | Ratio | RatioSD | Allocated | Alloc Ratio |
|------------------------------ |---------:|---------:|--------:|------:|--------:|----------:|------------:|
| &#39;baseline (no fence)&#39;         | 176.7 ns |  0.97 ns | 0.86 ns |  1.00 |    0.01 |         - |          NA |
| full-barrier                  | 159.5 ns |  3.12 ns | 2.92 ns |  0.90 |    0.02 |         - |          NA |
| interlocked-exchange          | 160.6 ns |  3.20 ns | 3.93 ns |  0.91 |    0.02 |         - |          NA |
| &#39;asymmetric (reclaimer side)&#39; | 757.9 ns | 10.10 ns | 7.88 ns |  4.29 |    0.05 |         - |          NA |
