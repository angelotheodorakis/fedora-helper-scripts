#!/bin/bash

set -eufx -o pipefail

# Check if script is running as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

############### Variables ##################

# Lets check if we have virtual machine (only needed for testing purposes)
systemd-detect-virt && is_virtual=true || is_virtual=false

nvidia_repo=$(grep -oP 'cpe.nvidia=\K(\w*)' /proc/cmdline) || nvidia_repo=

# Getting current OS details
OS_name=$(awk -F= '/^ID=/{gsub(/"/, "", $2); print tolower($2)}' /etc/os-release)
if [[ $OS_name == "\"centos\"" ]]; then
  OS_name="rhel"
fi
OS_version=$(awk -F= '/^VERSION_ID=/{gsub(/"/, "", $2); print tolower($2)}' /etc/os-release)

# defining distro to use for Nvidia repository
distro=$OS_name$OS_version

# Check if the provided repository is valid
if [ -z "$nvidia_repo" ]; then
  echo "Warning: when this script is executed manually, you need to define a repo. Only accepted options are 'rpmfusion' and 'nvidia'. "
  nvidia_repo="$1"
fi
if [ "$nvidia_repo" != "rpmfusion" ] && [ "$nvidia_repo" != "nvidia" ]; then
  echo "Warning: Unknown repository '$nvidia_repo'. Only accepted options are 'rpmfusion' and 'nvidia'. exiting..."
  exit 1
fi

echo "Using repository: $nvidia_repo"

# Check if we have a physical Nvidia device connected
has_nvidia=false
if /usr/sbin/lspci -mnn | grep -E 'VGA|3D controller' | grep NVIDIA | grep -q 10de; then
  has_nvidia=true
fi

# Getting latest installed kernel from /lib/modules
latest_kernel=$(find /lib/modules/ -maxdepth 1  -not -name '[a-zA-Z]*' -printf '%f\n' | sort -V | tail -1)


############## Functions ###################

# Set of functions which enable the selected Nvidia driver repo, rpmfusion or, Nvidia Cuda for Fedora and rhel
declare -A nvidia_repos
nvidia_repos[nvidia]="https://developer.download.nvidia.com/compute/cuda/repos/$distro/x86_64/cuda-$distro.repo"
nvidia_repos[rpmfusion,fedora,old]="rpmfusion-nonfree-nvidia-driver rpmfusion-nonfree-nvidia-driver-debuginfo"
nvidia_repos[rpmfusion,fedora,new]="setopt rpmfusion-nonfree-nvidia-driver.enabled=1 rpmfusion-nonfree-nvidia-driver-debuginfo.enabled=1"
nvidia_repos[rpmfusion,rhel]="https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-$OS_version.noarch.rpm https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-$OS_version.noarch.rpm"

is_nvidia_repo_enabled() {
  case $1 in
    nvidia) dnf repolist --enabled | grep "cuda-$distro" >/dev/null ;;
    rpmfusion) dnf repolist --enabled | grep rpmfusion-nonfree-nvidia-driver >/dev/null ;;
  esac
}

add_nvidia_repo() {
  local url=$1
  local dnf_add_repo='config-manager addrepo --from-repofile='
  if ((OS_version < 41)); then
    dnf_add_repo='config-manager --add-repo '
  fi
  # shellcheck disable=SC2086
  dnf $dnf_add_repo$url
}

enable_rpmfusion_fedora() {
  if ((OS_version < 41)); then
    # shellcheck disable=SC2086
    dnf config-manager --set-enabled ${nvidia_repos[rpmfusion,fedora,old]}
  else
    # shellcheck disable=SC2086
    dnf config-manager ${nvidia_repos[rpmfusion,fedora,new]}
  fi
}

enable_rpmfusion_rhel() {
  # shellcheck disable=SC2086
  dnf install -y --nogpgcheck ${nvidia_repos[rpmfusion,rhel]}
}

enable_nvidia_driver_repo() {
  echo "Enabling Nvidia driver repo..."
  if is_nvidia_repo_enabled "$nvidia_repo"; then
    echo " (up to date)"
    return
  fi
  case "$nvidia_repo $OS_name" in
    "nvidia"*)
      # shellcheck disable=SC2086
      add_nvidia_repo ${nvidia_repos[$nvidia_repo]}
      ;;
    "rpmfusion fedora")
      enable_rpmfusion_fedora
      ;;
    "rpmfusion rhel")
      enable_rpmfusion_rhel
      ;;
    *)
      echo "Unsupported OS: $OS_name or unknown repository: $nvidia_repo"
      exit 1
      ;;
  esac
}

# Function to configure which dkms module we expect to install for Fedora VS Centos with the Nvidia Cuda repo
dkms_module_version() {
  if [[ $OS_version -lt 41 && $OS_name != "rhel" ]] ; then
    rpm -q kmod-nvidia-latest-dkms --qf "%{VERSION}"
  else
    rpm -q kmod-nvidia-open-dkms --qf "%{VERSION}"
  fi
}

# Function to configure the correct dkms module we install for Fedora VS Centos with the Nvidia Cuda repo
# Sometimes configuration of the module under Anaconda might fail but kernel modules rebuild successfully on restart.
# We do not need to fail the script here if this happens.
dkms_inst_cmd() {
  nvidia_type="nvidia-open"
  if ((OS_version < 41)); then
    nvidia_type="nvidia"
  fi
  if ! dkms install "${nvidia_type}/$(dkms_module_version)" -k "$latest_kernel" --verbose; then
    echo "Warning: dkms install failed with exit code $?. If kernel modules don't rebuild on next reboot, install them manually."
  fi
}

# Function which configures the packages to install and kernel module to monitor if present
pkg_kmod_installs() {
  case $nvidia_repo in
    nvidia)
      PKGS="nvidia-driver nvidia-settings kernel-devel-$latest_kernel"
      if ((OS_version < 41)); then
        KMOD_RPM="kmod-nvidia-latest-dkms"
      else
        KMOD_RPM="kmod-nvidia-open-dkms"
      fi
      ;;
    rpmfusion)
      PKGS="akmod-nvidia nvidia-settings kernel-devel-$latest_kernel"
      KMOD_RPM="kmod-nvidia-$latest_kernel"
      ;;
    *)
      echo "Unknown repository '$nvidia_repo'"
      exit 1
      ;;
  esac
  INSTALLS=""
  for pkg in ${PKGS}; do
    if ! rpm -q "${pkg}" >/dev/null; then
      INSTALLS+=" ${pkg}"
    fi
  done
  INSTALLS=$(echo "${INSTALLS}" | xargs)
}

if [ "$OS_name" == "fedora" ]; then
  echo "Installing tool dependencies..."
  PKGS="fedora-workstation-repositories"
  INSTALLS=""

  for pkg in ${PKGS};
  do
    if ! rpm -q "${pkg}" >/dev/null; then
      INSTALLS+=" ${pkg}"
    fi
  done
  INSTALLS=$(echo "${INSTALLS}" | xargs)
  if [ -n "${INSTALLS}" ]; then
    # shellcheck disable=SC2086
    dnf install -y ${INSTALLS}
  else
    echo " (up to date)"
  fi
fi


############# Main script ##################

if $has_nvidia || $is_virtual; then

  enable_nvidia_driver_repo
  pkg_kmod_installs

  echo "Installing Nvidia driver..."

  if [ "$nvidia_repo" == "nvidia" ]; then
    if ((OS_version < 41)); then
      inst_validation='dnf module list --installed | grep "nvidia-driver" >/dev/null'
    else
      inst_validation=$( [ -n "${INSTALLS}" ] )
    fi
    if ! "${inst_validation[@]}"; then
      if ((OS_version < 41)); then
        dnf module install -y nvidia-driver:latest-dkms
      fi
      # shellcheck disable=SC2086
      dnf install -y ${INSTALLS}
      echo "Building kernel modules..."
      dkms_inst_cmd
      while ! rpm -q "${KMOD_RPM}" >/dev/null; do
        sleep 5
      done
      echo
      echo "DONE! You may now reboot your machine"
    elif ! (dkms status -k "$latest_kernel" | grep installed >/dev/null); then
      echo "ERROR: driver already installed but not built. Recovering..."
      dkms_inst_cmd
      echo "DONE! You may now reboot your machine"
    else
      echo " (up to date)"
    fi
  elif [ "$nvidia_repo" == "rpmfusion" ]; then
    if [ -n "${INSTALLS}" ]; then
      # shellcheck disable=SC2086
      dnf install -y ${INSTALLS}
      echo "Building kernel modules..."
      akmods --akmod nvidia --kernels "$latest_kernel"
      while ! rpm -q "${KMOD_RPM}" >/dev/null; do
        sleep 5
      done
      echo
      echo "DONE! You may now reboot your machine"
    elif ! rpm -q "${KMOD_RPM}" >/dev/null; then
      echo "ERROR: driver already installed but not built. Recovering..."
      akmods --akmod nvidia
      echo "DONE! You may now reboot your machine"
    else
      echo " (up to date)"
    fi
  fi
else
  echo "No Nvidia card detected, and not in a VM - not installing"
fi
