$path='C:\le\artifacts\x86-vm-d32-20260728\results.csv'
[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
