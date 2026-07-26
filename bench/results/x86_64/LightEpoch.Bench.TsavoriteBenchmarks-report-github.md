```

BenchmarkDotNet v0.14.0, Windows 11 (10.0.26200.8893) (Hyper-V)
Unknown processor
.NET SDK 10.0.302
  [Host]     : .NET 8.0.29 (8.0.2926.32403), X64 RyuJIT AVX2
  DefaultJob : .NET 8.0.29 (8.0.2926.32403), X64 RyuJIT AVX2


```
| Method                     | Mean     | Error    | StdDev   | Ratio | Allocated | Alloc Ratio |
|--------------------------- |---------:|---------:|---------:|------:|----------:|------------:|
| &#39;baseline (no fence)&#39;      | 19.33 ns | 0.072 ns | 0.060 ns |  1.00 |         - |          NA |
| full-barrier               | 20.59 ns | 0.204 ns | 0.181 ns |  1.06 |         - |          NA |
| interlocked-exchange       | 19.17 ns | 0.048 ns | 0.045 ns |  0.99 |         - |          NA |
| &#39;asymmetric (reader side)&#39; | 19.34 ns | 0.054 ns | 0.047 ns |  1.00 |         - |          NA |
