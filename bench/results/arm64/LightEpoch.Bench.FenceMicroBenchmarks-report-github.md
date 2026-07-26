```

BenchmarkDotNet v0.14.0, Ubuntu 24.04.4 LTS (Noble Numbat)
Unknown processor
.NET SDK 8.0.129
  [Host]     : .NET 8.0.29 (8.0.2926.32403), Arm64 RyuJIT AdvSIMD
  DefaultJob : .NET 8.0.29 (8.0.2926.32403), Arm64 RyuJIT AdvSIMD


```
| Method                       | Mean      | Error     | StdDev    | Ratio | RatioSD |
|----------------------------- |----------:|----------:|----------:|------:|--------:|
| &#39;store; load (no fence)&#39;     | 0.0514 ns | 0.0009 ns | 0.0008 ns |  1.00 |    0.02 |
| &#39;store; MemoryBarrier; load&#39; | 4.4258 ns | 0.0048 ns | 0.0040 ns | 86.10 |    1.36 |
