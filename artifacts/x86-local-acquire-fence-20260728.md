# x86-local-acquire-fence-20260728

Raw console output from each run in this matrix, concatenated. Empty stderr
streams are omitted; a stderr section here means that run reported a violation.

## quarantine-casannounce-acqfence-refresh-acqload-bare.out.txt
```
bare LightEpoch repro  impl=casannounce  rounds=1,000,000  deref=20000  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=acqload
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 1,000,000 rounds in 1.4s with NO violation. sampledRounds=23,063 drains=1,000,000 quarantined=1,000,000 sink=46153217396210

```

## quarantine-casannounce-acqfence-refresh-acqload-resume-and-refresh.out.txt
```
Resume + Refresh repro  impl=casannounce  rounds=1,000,000  deref=20000  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=acqload
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 1,000,000 rounds in 1.5s with NO violation. sampledRounds=34,259 drains=1,000,000 quarantined=1,000,000 sink=57958594478507

```

## quarantine-casannounce-acqfence-refresh-plain-bare.out.txt
```
bare LightEpoch repro  impl=casannounce  rounds=1,000,000  deref=20000  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=plain
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 1,000,000 rounds in 3.9s with NO violation. sampledRounds=178,228 drains=1,000,000 quarantined=1,000,000 sink=207461226203523

```

## quarantine-casannounce-acqfence-refresh-plain-resume-and-refresh.out.txt
```
Resume + Refresh repro  impl=casannounce  rounds=1,000,000  deref=20000  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=plain
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 1,000,000 rounds in 3.7s with NO violation. sampledRounds=163,005 drains=1,000,000 quarantined=1,000,000 sink=187986271740134

```

## results.csv
```
"name","impl","pattern","acquireOrder","refreshOrder","banner","status","exitCode","wallSeconds","reportedSeconds","violations","sampledRounds","slotReuse","stdout","stderr"
"sensitivity-baseline-bare","baseline","bare","","","LE_ACQUIRE_ORDER=cas  LE_REFRESH_ORDER=plain","CRASHED_NONZERO","1","4.421","4.3","1","","","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\sensitivity-baseline-bare.out.txt","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\sensitivity-baseline-bare.err.txt"
"sensitivity-baseline-resume-and-refresh","baseline","resume-and-refresh","","","LE_ACQUIRE_ORDER=cas  LE_REFRESH_ORDER=plain","CRASHED_NONZERO","1","9.656","9.6","2","","","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\sensitivity-baseline-resume-and-refresh.out.txt","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\sensitivity-baseline-resume-and-refresh.err.txt"
"quarantine-casannounce-acqfence-refresh-plain-bare","casannounce","bare","fence","","LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=plain","SURVIVED_EXIT0","0","3.951","3.9","","178,228","","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\quarantine-casannounce-acqfence-refresh-plain-bare.out.txt","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\quarantine-casannounce-acqfence-refresh-plain-bare.err.txt"
"quarantine-casannounce-acqfence-refresh-acqload-bare","casannounce","bare","fence","acqload","LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=acqload","SURVIVED_EXIT0","0","1.495","1.4","","23,063","","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\quarantine-casannounce-acqfence-refresh-acqload-bare.out.txt","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\quarantine-casannounce-acqfence-refresh-acqload-bare.err.txt"
"quarantine-casannounce-acqfence-refresh-plain-resume-and-refresh","casannounce","resume-and-refresh","fence","","LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=plain","SURVIVED_EXIT0","0","3.751","3.7","","163,005","","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\quarantine-casannounce-acqfence-refresh-plain-resume-and-refresh.out.txt","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\quarantine-casannounce-acqfence-refresh-plain-resume-and-refresh.err.txt"
"quarantine-casannounce-acqfence-refresh-acqload-resume-and-refresh","casannounce","resume-and-refresh","fence","acqload","LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=acqload","SURVIVED_EXIT0","0","1.553","1.5","","34,259","","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\quarantine-casannounce-acqfence-refresh-acqload-resume-and-refresh.out.txt","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\quarantine-casannounce-acqfence-refresh-acqload-resume-and-refresh.err.txt"
"shared-casannounce-acqfence-refresh-plain-bare","casannounce","bare","fence","","LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=plain","SURVIVED_EXIT0","0","4.687","4.6","","","8/8 slots held by >1 thread, max 8 distinct threads on one slot","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\shared-casannounce-acqfence-refresh-plain-bare.out.txt","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\shared-casannounce-acqfence-refresh-plain-bare.err.txt"
"shared-casannounce-acqfence-refresh-acqload-bare","casannounce","bare","fence","acqload","LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=acqload","SURVIVED_EXIT0","0","6.155","6.1","","","8/8 slots held by >1 thread, max 8 distinct threads on one slot","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\shared-casannounce-acqfence-refresh-acqload-bare.out.txt","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\shared-casannounce-acqfence-refresh-acqload-bare.err.txt"
"shared-casannounce-acqfence-refresh-plain-resume-and-refresh","casannounce","resume-and-refresh","fence","","LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=plain","SURVIVED_EXIT0","0","3.87","3.8","","","8/8 slots held by >1 thread, max 8 distinct threads on one slot","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\shared-casannounce-acqfence-refresh-plain-resume-and-refresh.out.txt","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\shared-casannounce-acqfence-refresh-plain-resume-and-refresh.err.txt"
"shared-casannounce-acqfence-refresh-acqload-resume-and-refresh","casannounce","resume-and-refresh","fence","acqload","LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=acqload","SURVIVED_EXIT0","0","5.46","5.4","","","8/8 slots held by >1 thread, max 8 distinct threads on one slot","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\shared-casannounce-acqfence-refresh-acqload-resume-and-refresh.out.txt","Q:\src\lightepoch-tla\artifacts\x86-local-acquire-fence-20260728\shared-casannounce-acqfence-refresh-acqload-resume-and-refresh.err.txt"
```

## sensitivity-baseline-bare.err.txt
```
USE-AFTER-FREE: reader read a quarantined page while protected. violations=1 firstRound=2,892,882 lastRound=2,892,882 deciles=[0 0 0 0 0 0 0 0 0 1] elapsed=4.3s

```

## sensitivity-baseline-bare.out.txt
```
bare LightEpoch repro  impl=baseline  rounds=3,000,000  deref=20000  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=cas  LE_REFRESH_ORDER=plain
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = baseline (LightEpoch, no fence)

```

## sensitivity-baseline-resume-and-refresh.err.txt
```
USE-AFTER-FREE: reader read a quarantined page while protected. violations=2 firstRound=526,942 lastRound=1,609,906 deciles=[0 1 0 0 0 1 0 0 0 0] elapsed=9.6s

```

## sensitivity-baseline-resume-and-refresh.out.txt
```
Resume + Refresh repro  impl=baseline  rounds=3,000,000  deref=20000  pairs=1  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=cas  LE_REFRESH_ORDER=plain
detection: quarantine (page pool + poison sentinel; no syscall in the race loop)
reclaimer: protected (Resume + Refresh each round), as Tsavorite drives the epoch in production
pair 0: cores(reclaimer=0,reader=2)
ops = baseline (LightEpoch, no fence)

```

## shared-casannounce-acqfence-refresh-acqload-bare.out.txt
```
bare LightEpoch shared-epoch repro  impl=casannounce  rounds=500,000  deref=5000  readers=8  slotSpace=2  reclaimerDelay=0
epoch sequence: Resume() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=acqload
detection: unmap (VirtualFree MEM_RELEASE; a fault is a hardware access violation)
topology: ONE shared epoch instance; reclaimer=core 0, readers=cores 2,4,6,8,10,12,14,16
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 500,000 rounds in 6.1s with NO fault. sink=24051336400
slot reuse: 8/8 slots held by >1 thread, max 8 distinct threads on one slot

```

## shared-casannounce-acqfence-refresh-acqload-resume-and-refresh.out.txt
```
Resume + Refresh shared-epoch repro  impl=casannounce  rounds=500,000  deref=5000  readers=8  slotSpace=2  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=acqload
detection: unmap (VirtualFree MEM_RELEASE; a fault is a hardware access violation)
topology: ONE shared epoch instance; reclaimer=core 0, readers=cores 2,4,6,8,10,12,14,16
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 500,000 rounds in 5.4s with NO fault. sink=13290934020
slot reuse: 8/8 slots held by >1 thread, max 8 distinct threads on one slot

```

## shared-casannounce-acqfence-refresh-plain-bare.out.txt
```
bare LightEpoch shared-epoch repro  impl=casannounce  rounds=500,000  deref=5000  readers=8  slotSpace=2  reclaimerDelay=0
epoch sequence: Resume() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=plain
detection: unmap (VirtualFree MEM_RELEASE; a fault is a hardware access violation)
topology: ONE shared epoch instance; reclaimer=core 0, readers=cores 2,4,6,8,10,12,14,16
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 500,000 rounds in 4.6s with NO fault. sink=23429362320
slot reuse: 8/8 slots held by >1 thread, max 8 distinct threads on one slot

```

## shared-casannounce-acqfence-refresh-plain-resume-and-refresh.out.txt
```
Resume + Refresh shared-epoch repro  impl=casannounce  rounds=500,000  deref=5000  readers=8  slotSpace=2  reclaimerDelay=0
epoch sequence: Resume() -> InternalRefresh()/ProtectAndDrain() -> access -> Suspend()
OS=Microsoft Windows 10.0.26200  Arch=X64  physicalCores=12 logicalProcessors=20 smtCores=8 numaNodes=1
ordering knobs: LE_ACQUIRE_ORDER=fence  LE_REFRESH_ORDER=plain
detection: unmap (VirtualFree MEM_RELEASE; a fault is a hardware access violation)
topology: ONE shared epoch instance; reclaimer=core 0, readers=cores 2,4,6,8,10,12,14,16
ops = cas-announce (FixedLightEpochWithCasAnnounce)
Completed 500,000 rounds in 3.8s with NO fault. sink=8060583440
slot reuse: 8/8 slots held by >1 thread, max 8 distinct threads on one slot

```

