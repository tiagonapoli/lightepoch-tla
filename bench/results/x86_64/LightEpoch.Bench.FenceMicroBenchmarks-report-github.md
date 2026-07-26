```

BenchmarkDotNet v0.14.0, Windows 11 (10.0.26200.8893) (Hyper-V)
Unknown processor
.NET SDK 10.0.302
  [Host]     : .NET 8.0.29 (8.0.2926.32403), X64 RyuJIT AVX2
  DefaultJob : .NET 8.0.29 (8.0.2926.32403), X64 RyuJIT AVX2


```
| Method                       | Mean      | Error     | StdDev    | Ratio  | RatioSD |
|----------------------------- |----------:|----------:|----------:|-------:|--------:|
| &#39;store; load (no fence)&#39;     | 0.0130 ns | 0.0031 ns | 0.0026 ns |   1.03 |    0.27 |
| &#39;store; MemoryBarrier; load&#39; | 7.6345 ns | 0.0181 ns | 0.0160 ns | 606.26 |  104.71 |
