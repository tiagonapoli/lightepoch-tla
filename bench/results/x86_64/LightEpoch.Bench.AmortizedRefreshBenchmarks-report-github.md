```

BenchmarkDotNet v0.14.0, Windows 11 (10.0.26200.8893) (Hyper-V)
Unknown processor
.NET SDK 10.0.302
  [Host]     : .NET 8.0.29 (8.0.2926.32403), X64 RyuJIT AVX2
  DefaultJob : .NET 8.0.29 (8.0.2926.32403), X64 RyuJIT AVX2


```
| Method                     | Mean     | Error     | StdDev    | Ratio | Allocated | Alloc Ratio |
|--------------------------- |---------:|----------:|----------:|------:|----------:|------------:|
| &#39;baseline (no fence)&#39;      | 8.231 ns | 0.0257 ns | 0.0215 ns |  1.00 |         - |          NA |
| full-barrier               | 7.940 ns | 0.0948 ns | 0.0792 ns |  0.96 |         - |          NA |
| interlocked-exchange       | 6.640 ns | 0.0271 ns | 0.0227 ns |  0.81 |         - |          NA |
| &#39;asymmetric (reader side)&#39; | 8.210 ns | 0.0205 ns | 0.0171 ns |  1.00 |         - |          NA |
