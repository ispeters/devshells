# The Colima VM used for Linux containers (CI reproduction, stdexec-ci), shared
# by shells/colima-docker.nix, which owns the VM's lifecycle, and by tools in
# other shells that only talk to it.
#
# The resources are sized for building Clang from source inside an amd64
# container under Rosetta. `colima start` applies explicitly passed
# --cpus/--memory/--disk to an existing stopped profile, so changing these
# takes effect on the next `devshell colima-docker` entry; disk can only grow.
# To reclaim the space:
#     colima delete --profile stdexec-repro
rec {
  profile = "stdexec-repro";
  cpus = 8;
  memoryGiB = 16;
  # Colima's default is 100 GiB, which the CI images alone nearly fill. The
  # disk image is sparse, so this only uses what's written.
  diskGiB = 200;
  # colima creates a Docker context named after the profile.
  dockerContext = "colima-${profile}";
}
