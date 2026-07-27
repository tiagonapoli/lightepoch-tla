using System;
using System.Runtime.InteropServices;

namespace LightEpoch.Repro.Common
{
    /// <summary>
    /// Cross-platform primitives the litmus needs: whole-page allocation that can
    /// be truly unmapped (so a later access faults), and thread-to-core pinning.
    /// </summary>
    internal static unsafe class Plat
    {
        static readonly bool IsWin = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);

        const uint MEM_COMMIT = 0x1000, MEM_RESERVE = 0x2000, MEM_RELEASE = 0x8000, PAGE_RW = 0x04;
        [DllImport("kernel32", SetLastError = true)] static extern IntPtr VirtualAlloc(IntPtr a, nuint s, uint t, uint p);
        [DllImport("kernel32", SetLastError = true)] static extern bool VirtualFree(IntPtr a, nuint s, uint t);
        [DllImport("kernel32")] static extern IntPtr GetCurrentThread();
        [DllImport("kernel32")] static extern UIntPtr SetThreadAffinityMask(IntPtr h, UIntPtr m);

        const int PROT_READ = 0x1, PROT_WRITE = 0x2, MAP_PRIVATE = 0x02, MAP_ANON = 0x20;
        static readonly IntPtr MAP_FAILED = new IntPtr(-1);
        [DllImport("libc", SetLastError = true)] static extern IntPtr mmap(IntPtr a, nuint len, int prot, int flags, int fd, nint off);
        [DllImport("libc", SetLastError = true)] static extern int munmap(IntPtr a, nuint len);
        [DllImport("libc", SetLastError = true)] static extern int sched_setaffinity(int pid, nuint sz, ref ulong mask);

        public static byte* Alloc(nuint bytes)
        {
            if (IsWin)
            {
                var p = VirtualAlloc(IntPtr.Zero, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_RW);
                if (p == IntPtr.Zero) throw new OutOfMemoryException("VirtualAlloc");
                return (byte*)p;
            }
            var m = mmap(IntPtr.Zero, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
            if (m == MAP_FAILED) throw new OutOfMemoryException("mmap errno=" + Marshal.GetLastWin32Error());
            return (byte*)m;
        }

        /// <summary>Fully unmap the region; any subsequent access to it faults.</summary>
        public static void Free(byte* p, nuint bytes)
        {
            if (IsWin) _ = VirtualFree((IntPtr)p, 0, MEM_RELEASE);
            else _ = munmap((IntPtr)p, bytes);
        }

        public static void Pin(int core)
        {
            if (IsWin) _ = SetThreadAffinityMask(GetCurrentThread(), (UIntPtr)(1UL << core));
            else { ulong m = 1UL << core; _ = sched_setaffinity(0, (nuint)sizeof(ulong), ref m); }
        }
    }
}
