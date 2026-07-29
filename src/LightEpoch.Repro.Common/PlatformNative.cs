using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace LightEpoch.Repro.Common
{
    /// <summary>
    /// The two OS primitives the repro needs: whole-page allocation that can be truly
    /// unmapped (so a later access faults), and thread-to-core pinning.
    ///
    /// Both a Windows and a Linux backend are provided because the two architectures the
    /// study needs are not both reachable from one OS: Azure offers no Windows ARM64
    /// server image, so the Neoverse ARM64 measurements have to run on Linux.
    /// </summary>
    internal static unsafe class PlatformNative
    {
        // ---- Windows ----
        private const uint MEM_COMMIT = 0x1000, MEM_RESERVE = 0x2000, MEM_RELEASE = 0x8000, PAGE_RW = 0x04;
        [DllImport("kernel32", SetLastError = true)] private static extern IntPtr VirtualAlloc(IntPtr a, nuint s, uint t, uint p);
        [DllImport("kernel32", SetLastError = true)] private static extern bool VirtualFree(IntPtr a, nuint s, uint t);
        [DllImport("kernel32")] private static extern IntPtr GetCurrentThread();
        [DllImport("kernel32", SetLastError = true)] private static extern UIntPtr SetThreadAffinityMask(IntPtr h, UIntPtr m);

        // ---- Linux ----
        private const int PROT_READ = 0x1, PROT_WRITE = 0x2;
        private const int MAP_PRIVATE = 0x02, MAP_ANONYMOUS = 0x20;
        [DllImport("libc", SetLastError = true, EntryPoint = "mmap")] private static extern IntPtr LinuxMmap(IntPtr addr, nuint length, int prot, int flags, int fd, long offset);
        [DllImport("libc", SetLastError = true, EntryPoint = "munmap")] private static extern int LinuxMunmap(IntPtr addr, nuint length);
        [DllImport("libc", SetLastError = true, EntryPoint = "sched_setaffinity")] private static extern int LinuxSchedSetAffinity(int pid, nuint cpuSetSize, ulong* mask);

        /// <summary>Bytes in the kernel cpu_set_t passed to sched_setaffinity (1024 CPUs).</summary>
        private const int CpuSetBytes = 128;

        static PlatformNative()
        {
            if (!OperatingSystem.IsWindows() && !OperatingSystem.IsLinux())
                throw new PlatformNotSupportedException("The repro is supported only on Windows and Linux.");
        }

        /// <summary>
        /// Allocates a standalone reservation, committed and readable/writable so the
        /// reader can dereference it. <see cref="Free"/> unmaps it, which on Windows
        /// requires the base address of a whole VirtualAlloc reservation — so each page
        /// must come from its own call rather than be carved out of a larger block. That
        /// unmapping is what makes the epoch's use-after-free observable as a hardware
        /// access violation.
        /// </summary>
        public static byte* Alloc(nuint bytes)
        {
            if (OperatingSystem.IsWindows())
            {
                var pointer = VirtualAlloc(IntPtr.Zero, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_RW);
                if (pointer == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "VirtualAlloc failed.");
                return (byte*)pointer;
            }

            var mapped = LinuxMmap(IntPtr.Zero, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (mapped == new IntPtr(-1))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "mmap failed.");

            return (byte*)mapped;
        }

        /// <summary>Fully unmap the region; any subsequent access to it faults.</summary>
        public static void Free(byte* p, nuint bytes)
        {
            if (OperatingSystem.IsWindows())
            {
                // MEM_RELEASE requires dwSize to be 0 and releases the whole reservation, so
                // the range leaves the process's page tables and a later access raises
                // STATUS_ACCESS_VIOLATION (0xC0000005). If a later VirtualAlloc happens to
                // reuse the range the access silently succeeds instead, which can only hide a
                // violation, never manufacture one.
                if (!VirtualFree((IntPtr)p, 0, MEM_RELEASE))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "VirtualFree failed.");

                return;
            }

            // munmap needs the length, and unlike MEM_RELEASE it takes it explicitly. The
            // effect is the same: the range leaves the page tables and a later access raises
            // SIGSEGV, which the CLR surfaces as an AccessViolationException.
            if (LinuxMunmap((IntPtr)p, bytes) != 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "munmap failed.");
        }

        public static void Pin(int core)
        {
            if (OperatingSystem.IsWindows())
            {
                int affinityBits = UIntPtr.Size * 8;
                if ((uint)core >= affinityBits)
                    throw new ArgumentOutOfRangeException(nameof(core), core, $"Core must be in the current processor group (0-{affinityBits - 1}).");

                UIntPtr mask = (UIntPtr)(1UL << core);
                if (SetThreadAffinityMask(GetCurrentThread(), mask) == UIntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "SetThreadAffinityMask failed.");

                return;
            }

            if ((uint)core >= CpuSetBytes * 8)
                throw new ArgumentOutOfRangeException(nameof(core), core, $"Core must be in 0-{(CpuSetBytes * 8) - 1}.");

            var cpuMask = stackalloc ulong[CpuSetBytes / sizeof(ulong)];
            for (int i = 0; i < CpuSetBytes / sizeof(ulong); i++)
                cpuMask[i] = 0;

            cpuMask[core / 64] = 1UL << (core % 64);

            // pid 0 means the calling thread, which is what we want: every Linux thread is a
            // task with its own affinity mask.
            if (LinuxSchedSetAffinity(0, CpuSetBytes, cpuMask) != 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "sched_setaffinity failed.");
        }
    }
}
