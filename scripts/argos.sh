#!/usr/bin/env bash

########### NOTE ##############
# Install argos and gnome shell with: dnf install -y gnome-shell-extension-argos gnome-terminal
# Place the helper scripts in /usr/local/bin

echo " | iconName=fedora-logo-icon"
echo "---"

echo " Enable Secure Boot (<span color='red'><tt>Lenovo Only!</tt></span>) | iconName=channel-secure-symbolic bash=fedora_secure_boot.sh terminal=true "
echo " Unlock LUKS with TPM2.0 | iconName=system-lock-screen-symbolic bash=fedora_unlock_tpm.sh terminal=true "
echo " Install Nvidia rpmfusion driver | iconName=system-component-driver bash=fedora_nvidia_setup.sh terminal=true "
echo " Update your system | iconName=system-software-update bash=fedora_system_updates.sh terminal=true "
