# Every version the golden image installs, pinned exactly (T-1.18, #250).
#
# ONE FILE, BECAUSE TWO WOULD DISAGREE
#
# Terraform must install the same k3s the image contains. Keeping the number
# here and repeating it in a .tfvars is how those drift, and a node running a
# different k3s from the one its image was tested with fails in ways that look
# like anything except a version mismatch. `make golden-image` writes the
# resolved versions onto the snapshot as labels, and terraform reads them back
# rather than being told again.
#
# NEVER `latest`, and never an unpinned package install. A golden image whose
# contents depend on the day it was built is not a golden image -- it is a
# cache of whatever upstream happened to be serving, and two builds a week
# apart produce different clusters for reasons nobody recorded.
#
# To upgrade: change the version AND its checksum together, in one commit, and
# rebuild. The checksum is not decoration -- it is the only thing standing
# between this image and whatever a compromised mirror serves.

# k3s. Must match `k3s_version` in the cluster module, and the build asserts it.
k3s_version = "v1.36.3+k3s1"
k3s_sha256  = "2f98a9f8fe5782479ee2d54e70a1b10a7f6fd4cae8d38ed3098452dc6eed76b5"

# Tailscale, installed as the static tarball to /usr/local, which is what the
# module's own bootstrap does -- so a node built from this image and a node
# built the old way put the binaries in the same place.
tailscale_version = "1.102.3"
tailscale_sha256  = "36ddd9b51be57ffc2990cf76323cfa13643bfbb1b8a969f6183fa164741cdef5"

# Where the cluster actually runs. A snapshot is region-scoped; building it
# somewhere the cluster is not means `apply` cannot find an image.
location = "fsn1"

# Build server. Any type works if its disk is >= 40GiB; this is the cheapest
# that qualifies, and it exists for about five minutes.
server_type = "cx23"
