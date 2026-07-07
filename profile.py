"""PYNC benchmarking cluster.

- N bare-metal nodes (default 4x c6525-25g) to allow running benchmarks in parallel.
- Uses a fixed CloudLab long-term dataset (DATASET_URN).
  Each node mounts its own rwclone at /nfs, so writes are local only.

This is run by pync/evaluation/run.py in the main repo.
"""

import geni.rspec.emulab  # noqa: F401  (enables best_effort/vlan_tagging extensions)
from geni import portal
from geni.rspec import pg

OS_IMAGE = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU24-64-STD"
# The long-term dataset holding the benchmark inputs; mounted at /nfs on every node.
DATASET_URN = "urn:publicid:IDN+utah.cloudlab.us:ucla-progsoftsys-pg0+ltdataset+Pync"

pc = portal.Context()

pc.defineParameter(
    "nodeCount",
    "Number of nodes",
    portal.ParameterType.INTEGER,
    4,
    longDescription="Benchmarks are distributed one per node",
)
pc.defineParameter(
    "hardware", "Hardware type", portal.ParameterType.STRING, "c6525-25g"
)
pc.defineParameter(
    "datasetRW",
    "Attach the dataset read-write to a single node (populate mode)",
    portal.ParameterType.BOOLEAN,
    False,
    longDescription="Off (default): every node gets a private rwclone of the "
    "dataset for reads. On: the real dataset is mounted read-write on node0 only "
    "(single-writer) so a run's downloaded inputs PERSIST into it",
)
pc.defineParameter(
    "localBSSize",
    "Local scratch blockstore size per node, in GB",
    portal.ParameterType.INTEGER,
    400,
    longDescription="Mounted at /mydata on every node (required by the setup scripts); "
    "holds benchmarks. 400GB targets the 480GB SSD on c6525-25g.",
)

params = pc.bindParameters()

if params.nodeCount < 1:
    pc.reportError(portal.ParameterError("nodeCount must be >= 1", ["nodeCount"]))
if params.localBSSize < 1:
    pc.reportError(portal.ParameterError("localBSSize must be >= 1", ["localBSSize"]))
if params.datasetRW and params.nodeCount != 1:
    # Populate mounts the dataset read-write, which is single-writer.
    pc.reportError(
        portal.ParameterError("datasetRW requires nodeCount == 1", ["nodeCount"])
    )
pc.verifyParameters()

request = pc.makeRequestRSpec()


# voodoo taken from https://github.com/lbstoller/nfs-dataset/blob/master/profile.py
def attach_dataset(node, name, ifname, rwclone):
    """Attach the dataset to `node` at /nfs over its own link (a private rwclone
    for runs, or the real read-write volume in populate mode)."""
    ds = request.RemoteBlockstore(name, "/nfs")
    ds.dataset = DATASET_URN
    if rwclone:
        ds.rwclone = True
    link = request.Link(name + "link")
    link.addInterface(ds.interface)
    link.addInterface(node.addInterface(ifname))
    link.best_effort = True
    link.vlan_tagging = True
    link.link_multiplexing = True


for i in range(params.nodeCount):
    node = request.RawPC("node%d" % i)
    node.hardware_type = params.hardware
    node.disk_image = OS_IMAGE
    bs = node.Blockstore("bs%d" % i, "/mydata")
    bs.size = "%dGB" % params.localBSSize
    attach_dataset(node, "dsnode%d" % i, "ifds%d" % i, rwclone=not params.datasetRW)
    node.addService(
        pg.Execute(
            shell="bash",
            command="sudo /bin/bash /local/repository/initial-setup.sh",
        )
    )
    node.addService(
        pg.Execute(
            shell="bash",
            command="sudo /bin/bash /local/repository/boot-setup.sh",
        )
    )

pc.printRequestRSpec(request)
