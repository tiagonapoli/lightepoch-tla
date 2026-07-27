using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace LightEpoch.Repro.Common
{
    /// <summary>
    /// Windows primitives the repro needs: whole-page allocation that can be
    /// truly unmapped (so a later access faults), and thread-to-core pinning.
    /// </summary>
    internal static unsafe class WindowsNative
    {
        const uint MEM_COMMIT = 0x1000, MEM_RESERVE = 0x2000, MEM_RELEASE = 0x8000, PAGE_RW = 0x04;
        [DllImport("kernel32", SetLastError = true)] static extern IntPtr VirtualAlloc(IntPtr a, nuint s, uint t, uint p);
        [DllImport("kernel32", SetLastError = true)] static extern bool VirtualFree(IntPtr a, nuint s, uint t);
        [DllImport("kernel32")] static extern IntPtr GetCurrentThread();
        [DllImport("kernel32", SetLastError = true)] static extern UIntPtr SetThreadAffinityMask(IntPtr h, UIntPtr m);

        public static byte* Alloc(nuint bytes)
        {
            EnsureWindows();
            var pointer = VirtualAlloc(IntPtr.Zero, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_RW);
            if (pointer == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "VirtualAlloc failed.");
            return (byte*)pointer;
        }

        /// <summary>Fully unmap the region; any subsequent access to it faults.</summary>
        public static void Free(byte* p, nuint bytes)
        {
            _ = bytes;
            EnsureWindows();
            if (!VirtualFree((IntPtr)p, 0, MEM_RELEASE))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "VirtualFree failed.");
        }

        public static void Pin(int core)
        {
            EnsureWindows();
            int affinityBits = UIntPtr.Size * 8;
            if ((uint)core >= affinityBits)
                throw new ArgumentOutOfRangeException(
                    nameof(core), core, $"Core must be in the current processor group (0-{affinityBits - 1}).");

            UIntPtr mask = (UIntPtr)(1UL << core);
            if (SetThreadAffinityMask(GetCurrentThread(), mask) == UIntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetThreadAffinityMask failed.");
        }

        static void EnsureWindows()
        {
            if (!OperatingSystem.IsWindows())
                throw new PlatformNotSupportedException("The repro is supported only on Windows.");
        }
    }
}
