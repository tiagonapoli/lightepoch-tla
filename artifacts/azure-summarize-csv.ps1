Import-Csv C:\le\artifacts\x86-vm-d32-20260728\results.csv | Select-Object name,status,exitCode,wallSeconds,reportedSeconds,violations,sampledRounds,slotReuse | ConvertTo-Csv -NoTypeInformation
