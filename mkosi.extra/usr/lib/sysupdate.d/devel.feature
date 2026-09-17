[Feature]
Description=Native build toolchain (gcc, binutils, make, cmake, common -devel)
Documentation=https://github.com/aboglioli/myosi
# Operator-opt-in per host — a sealed appliance has no use for a compiler,
# and the -devel trees are only meaningful on a machine that builds.
Enabled=false
