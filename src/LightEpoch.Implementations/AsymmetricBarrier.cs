using System;
using System.Runtime.InteropServices;

namespace Tsavorite.core
{
    /// <summary>
    /// Process-wide ("asymmetric") memory barrier.
    ///
    /// The epoch enter path has a StoreLoad hazard: a reader stores its epoch
    /// announce, then loads a shared pointer; the reclaimer stores the unlink,
    /// then loads the reader's announce. Closing it with a full fence on every
    /// reader enter is correct but costs a barrier (e.g. <c>dmb ish</c> on ARM64)
    /// on the hot path.
    ///
    /// The asymmetric alternative moves the entire cost to the RARE reclaimer:
    /// readers announce with a cheap plain store (zero fence), and before the
    /// reclaimer scans the epoch table it issues a process-wide barrier that
    /// forces every other core to drain its store buffer. This is exactly the
    /// technique used by RCU (<c>membarrier</c>) and by managed runtimes'
    /// garbage collectors (<c>FlushProcessWriteBuffers</c>).
    /// </summary>
    internal static class AsymmetricBarrier
    {
        static readonly bool IsWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);

        [DllImport("kernel32")]
        static extern void FlushProcessWriteBuffers();

        // Linux membarrier(2) — issued via the raw syscall because glibc has no
        // stable wrapper across the versions we target. Numbers are per-arch.
        const int SYS_membarrier_x64 = 324;
        const int SYS_membarrier_arm64 = 283;

        const int MEMBARRIER_CMD_GLOBAL = 1 << 0;
        const int MEMBARRIER_CMD_PRIVATE_EXPEDITED = 1 << 3;
        const int MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED = 1 << 4;

        [DllImport("libc", SetLastError = true)]
        static extern long syscall(long number, long arg1, long arg2, long arg3);

        static readonly long MembarrierNr =
            RuntimeInformation.ProcessArchitecture == Architecture.Arm64
                ? SYS_membarrier_arm64
                : SYS_membarrier_x64;

        // Whether the fast, registered private-expedited path is usable.
        static readonly bool PrivateExpeditedReady = TryRegisterPrivateExpedited();

        static bool TryRegisterPrivateExpedited()
        {
            if (IsWindows)
                return false;
            try
            {
                return syscall(MembarrierNr, MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED, 0, 0) == 0;
            }
            catch (DllNotFoundException)
            {
                return false;
            }
            catch (EntryPointNotFoundException)
            {
                return false;
            }
        }

        /// <summary>
        /// Force every other core in this process to become visible to the caller
        /// with respect to prior stores (a system-wide StoreLoad drain).
        /// </summary>
        public static void FullBarrierAllCores()
        {
            if (IsWindows)
            {
                FlushProcessWriteBuffers();
                return;
            }

            long cmd = PrivateExpeditedReady ? MEMBARRIER_CMD_PRIVATE_EXPEDITED : MEMBARRIER_CMD_GLOBAL;
            if (syscall(MembarrierNr, cmd, 0, 0) != 0)
                System.Threading.Interlocked.MemoryBarrier(); // conservative local fallback
        }
    }
}
