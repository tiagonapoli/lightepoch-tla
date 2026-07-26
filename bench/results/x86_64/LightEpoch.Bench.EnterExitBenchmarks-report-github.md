```

BenchmarkDotNet v0.14.0, Windows 11 (10.0.26200.8893) (Hyper-V)
Unknown processor
.NET SDK 10.0.302
  [Host]     : .NET 8.0.29 (8.0.2926.32403), X64 RyuJIT AVX2
  DefaultJob : .NET 8.0.29 (8.0.2926.32403), X64 RyuJIT AVX2


```
| Method                     | Mean     | Error    | StdDev   | Ratio | Allocated | Alloc Ratio |
|--------------------------- |---------:|---------:|---------:|------:|----------:|------------:|
| &#39;baseline (no fence)&#39;      | 16.11 ns | 0.043 ns | 0.038 ns |  1.00 |         - |          NA |
| full-barrier               | 17.79 ns | 0.066 ns | 0.059 ns |  1.10 |         - |          NA |
| interlocked-exchange       | 17.57 ns | 0.106 ns | 0.094 ns |  1.09 |         - |          NA |
| &#39;asymmetric (reader side)&#39; | 17.01 ns | 0.040 ns | 0.038 ns |  1.06 |         - |          NA |
