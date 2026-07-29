[Feature]
Description=OpenZFS kernel module + userspace (zfs, zpool, zed)
Documentation=https://openzfs.github.io/openzfs-docs/
# Operator-opt-in per host — only enable on machines that actually
# host ZFS pools. ZFS taints the kernel as proprietary (CDDL) at
# module load, which is fine but worth knowing.
Enabled=false
