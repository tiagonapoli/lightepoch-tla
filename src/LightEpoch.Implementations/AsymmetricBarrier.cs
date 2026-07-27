using System;
using System.Runtime.InteropServices;

namespace LightEpoch.Core
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
    /// technique exposed on Windows by <c>FlushProcessWriteBuffers</c>.
    /// </summary>
    internal static class AsymmetricBarrier
    {
        [DllImport("kernel32")]
        private static extern void FlushProcessWriteBuffers();

        /// <summary>
        /// Force every other core in this process to become visible to the caller
        /// with respect to prior stores (a system-wide StoreLoad drain).
        /// </summary>
        public static void FullBarrierAllCores()
        {
            if (!OperatingSystem.IsWindows())
                throw new PlatformNotSupportedException("The asymmetric barrier requires Windows FlushProcessWriteBuffers.");

            FlushProcessWriteBuffers();
        }
    }
}
