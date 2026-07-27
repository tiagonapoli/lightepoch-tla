using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace LightEpoch.Repro.Common
{
    /// <summary>
    /// Physical-core topology. The litmus needs each thread on its own physical
    /// core: SMT siblings share a store buffer and load/store queues, so an
    /// announce store is visible to a sibling almost immediately and the
    /// Store-Buffer window the repro depends on never opens.
    /// </summary>
    internal static class CoreTopology
    {
        const int RelationProcessorCore = 0;
        const int RelationNumaNode = 1;

        [DllImport("kernel32", SetLastError = true)]
        static extern bool GetLogicalProcessorInformationEx(int relationshipType, IntPtr buffer, ref uint returnedLength);

        internal readonly struct PhysicalCore
        {
            public PhysicalCore(int representativeLogicalProcessor, int[] logicalProcessors, int efficiencyClass, int numaNode)
            {
                RepresentativeLogicalProcessor = representativeLogicalProcessor;
                LogicalProcessors = logicalProcessors;
                EfficiencyClass = efficiencyClass;
                NumaNode = numaNode;
            }

            /// <summary>One logical processor to pin to; the rest are its SMT siblings.</summary>
            public int RepresentativeLogicalProcessor { get; }
            public int[] LogicalProcessors { get; }
            public int EfficiencyClass { get; }
            public int NumaNode { get; }
            public bool IsSmt => LogicalProcessors.Length > 1;
        }

        /// <summary>
        /// Enumerates physical cores. Throws if the OS query fails: without real
        /// topology the harness cannot tell SMT siblings apart, and a run that
        /// unknowingly pins both threads to one physical core reports "no fault"
        /// for the wrong reason.
        /// </summary>
        public static IReadOnlyList<PhysicalCore> Enumerate()
        {
            var numaByLogicalProcessor = NumaNodesByLogicalProcessor();
            var cores = new List<PhysicalCore>();
            uint length = 0;
            GetLogicalProcessorInformationEx(RelationProcessorCore, IntPtr.Zero, ref length);
            if (length == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetLogicalProcessorInformationEx(RelationProcessorCore) did not report a buffer size.");

            IntPtr buffer = Marshal.AllocHGlobal((int)length);
            try
            {
                if (!GetLogicalProcessorInformationEx(RelationProcessorCore, buffer, ref length))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "GetLogicalProcessorInformationEx(RelationProcessorCore) failed.");

                IntPtr cursor = buffer;
                long end = buffer.ToInt64() + length;
                while (cursor.ToInt64() < end)
                {
                    int relationship = Marshal.ReadInt32(cursor, 0);
                    int size = Marshal.ReadInt32(cursor, 4);
                    if (size <= 0)
                        break;

                    if (relationship == RelationProcessorCore)
                    {
                        int efficiencyClass = Marshal.ReadByte(cursor, 9);
                        ulong mask = unchecked((ulong)Marshal.ReadIntPtr(cursor, 32).ToInt64());
                        var logicalProcessors = new List<int>();
                        for (int bit = 0; bit < 64; bit++)
                        {
                            if ((mask & (1UL << bit)) != 0)
                                logicalProcessors.Add(bit);
                        }

                        if (logicalProcessors.Count > 0)
                        {
                            int representative = logicalProcessors[0];
                            numaByLogicalProcessor.TryGetValue(representative, out int numaNode);
                            cores.Add(new PhysicalCore(
                                representative, logicalProcessors.ToArray(), efficiencyClass, numaNode));
                        }
                    }

                    cursor = IntPtr.Add(cursor, size);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }

            if (cores.Count == 0)
                throw new InvalidOperationException("GetLogicalProcessorInformationEx(RelationProcessorCore) reported no physical cores.");

            return cores;
        }

        static Dictionary<int, int> NumaNodesByLogicalProcessor()
        {
            var map = new Dictionary<int, int>();
            uint length = 0;
            GetLogicalProcessorInformationEx(RelationNumaNode, IntPtr.Zero, ref length);
            if (length == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetLogicalProcessorInformationEx(RelationNumaNode) did not report a buffer size.");

            IntPtr buffer = Marshal.AllocHGlobal((int)length);
            try
            {
                if (!GetLogicalProcessorInformationEx(RelationNumaNode, buffer, ref length))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "GetLogicalProcessorInformationEx(RelationNumaNode) failed.");

                IntPtr cursor = buffer;
                long end = buffer.ToInt64() + length;
                while (cursor.ToInt64() < end)
                {
                    int relationship = Marshal.ReadInt32(cursor, 0);
                    int size = Marshal.ReadInt32(cursor, 4);
                    if (size <= 0)
                        break;

                    if (relationship == RelationNumaNode)
                    {
                        int node = Marshal.ReadInt32(cursor, 8);
                        ulong mask = unchecked((ulong)Marshal.ReadIntPtr(cursor, 32).ToInt64());
                        for (int bit = 0; bit < 64; bit++)
                        {
                            if ((mask & (1UL << bit)) != 0)
                                map[bit] = node;
                        }
                    }

                    cursor = IntPtr.Add(cursor, size);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }

            return map;
        }

        /// <summary>
        /// Picks distinct physical cores to pin to, preferring the most
        /// performant efficiency class so a hybrid CPU does not mix core types
        /// within one litmus pair.
        /// </summary>
        public static int[] SelectDistinctPhysicalCores(int count, int? seed)
        {
            var cores = Enumerate();
            var byClass = new Dictionary<int, List<PhysicalCore>>();
            foreach (var core in cores)
            {
                if (!byClass.TryGetValue(core.EfficiencyClass, out var list))
                    byClass[core.EfficiencyClass] = list = new List<PhysicalCore>();
                list.Add(core);
            }

            List<PhysicalCore> pool = null;
            int bestClass = int.MinValue;
            foreach (var pair in byClass)
            {
                if (pair.Value.Count >= count && pair.Key > bestClass)
                {
                    bestClass = pair.Key;
                    pool = pair.Value;
                }
            }

            pool ??= new List<PhysicalCore>(cores);
            if (pool.Count < count)
                throw new InvalidOperationException(
                    $"need {count} distinct physical cores but only {pool.Count} are available");

            var candidates = new List<int>();
            foreach (var core in pool)
                candidates.Add(core.RepresentativeLogicalProcessor);

            if (seed.HasValue)
            {
                var random = new Random(seed.Value);
                for (int i = candidates.Count - 1; i > 0; i--)
                {
                    int j = random.Next(i + 1);
                    (candidates[i], candidates[j]) = (candidates[j], candidates[i]);
                }
            }

            return candidates.GetRange(0, count).ToArray();
        }

        /// <summary>
        /// Picks core pairs whose two threads sit on different NUMA nodes. A
        /// store cannot leave the store buffer until the core owns the line
        /// exclusively, so a remote-socket RFO keeps the announce buffered far
        /// longer and widens the Store-Buffer window this repro depends on.
        /// </summary>
        public static int[] SelectCrossNumaPairs(int pairs, int? seed)
        {
            var byNode = new Dictionary<int, List<int>>();
            foreach (var core in Enumerate())
            {
                if (!byNode.TryGetValue(core.NumaNode, out var list))
                    byNode[core.NumaNode] = list = new List<int>();
                list.Add(core.RepresentativeLogicalProcessor);
            }

            var nodes = new List<int>(byNode.Keys);
            nodes.Sort();
            if (nodes.Count < 2)
                throw new InvalidOperationException(
                    $"--cross-numa needs at least 2 NUMA nodes but this machine reports {nodes.Count}");

            var random = seed.HasValue ? new Random(seed.Value) : null;
            if (random != null)
            {
                foreach (var list in byNode.Values)
                {
                    for (int i = list.Count - 1; i > 0; i--)
                    {
                        int j = random.Next(i + 1);
                        (list[i], list[j]) = (list[j], list[i]);
                    }
                }
            }

            var selected = new List<int>();
            var cursors = new Dictionary<int, int>();
            foreach (var node in nodes)
                cursors[node] = 0;

            for (int p = 0; p < pairs; p++)
            {
                int nodeA = nodes[(2 * p) % nodes.Count];
                int nodeB = nodes[((2 * p) + 1) % nodes.Count];
                if (nodeA == nodeB)
                    nodeB = nodes[(nodes.IndexOf(nodeA) + 1) % nodes.Count];

                if (cursors[nodeA] >= byNode[nodeA].Count || cursors[nodeB] >= byNode[nodeB].Count)
                    throw new InvalidOperationException($"not enough cores to build {pairs} cross-NUMA pairs");

                selected.Add(byNode[nodeA][cursors[nodeA]++]);
                selected.Add(byNode[nodeB][cursors[nodeB]++]);
            }

            return selected.ToArray();
        }

        public static string Describe()
        {
            var cores = Enumerate();
            int smtCores = 0;
            var nodes = new HashSet<int>();
            foreach (var core in cores)
            {
                if (core.IsSmt)
                    smtCores++;
                nodes.Add(core.NumaNode);
            }

            return $"physicalCores={cores.Count} logicalProcessors={Environment.ProcessorCount} " +
                   $"smtCores={smtCores} numaNodes={nodes.Count}";
        }
    }
}
