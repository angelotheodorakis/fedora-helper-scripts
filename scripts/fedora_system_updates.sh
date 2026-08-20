#!/bin/bash

# Bash text color
Color_Off='\033[0m' # Text Reset
Red='\033[1;91m'    # Red
Yellow='\033[1;93m' # Yellow
Green='\033[1;32m' # Green

# Make sure file is run as a root.
if [ "$EUID" -ne 0 ]; then
    echo -e "fedora_system_updates requires ${Yellow}root access${Color_Off}. You'll be prompted to enter your password, typing will be hidden. \n"
    exec sudo "$0" "$@"
fi

log_entry() {
  local action="$1"
  local status="$2"
  local msg="$3"
  logger -p user."${status}" -t "${action}" "fedora_system_updates: ${msg}"
}

log_entry "started_dnf_updates" "info" "operating system updates started" 

# Run system updates
echo -e "${Yellow}Running operating system updates...${Color_Off}\n"
dnf -y upgrade --refresh --skip-unavailable
if [ $? -ne 0 ] && [ $? -ne 1 ]; then
    echo -e "${Red}ERROR${Color_Off}: dnf upgrade failed (exit code $?)."
    log_entry "completed_dnf_updates" "err" "operating system updates failed" 
    exit 1
fi
echo -e "${Green}operating system updates completed.${Color_Off}\n"

log_entry "completed_dnf_updates" "info" "operating system updates completed" 

# Update flatpaks
if command -v flatpak >/dev/null 2>&1
then
    read -r -p "Would you like to update your flatpak applications? (y/n) " choice
    case "$choice" in
    y|Y )
        echo -e "${Yellow}Updating flatpak apps...${Color_Off}\n"
        flatpak update -y
        echo -e "${Green}flatpak apps updated.${Color_Off}\n"
        log_entry "flatpak_updates" "info" "flatpak apps updated" 
        ;;
    n|N )
        echo -e "${Yellow}Skipping flatpak apps...${Color_Off}\n"
        ;;
    * )
        echo -e "${Red} Invalid option entered. ${Color_Off}\n"
        ;;
    esac
fi

# Update firmware packages with fwupdmgr
if command -v fwupdmgr >/dev/null 2>&1
then
    echo -e "We will now attempt to update your firmware. This is a critical operation that requires a device restart and requires care to be done safely.\n"
    echo -e "${Yellow}Proceed with caution!${Color_Off}\n"
    read -r -p "Would you like to update your device firmware? (y/n) " choice
    case "$choice" in
    y|Y )
        echo -e "${Yellow}Updating device firmware...${Color_Off}\n"
        fwupdmgr update
        echo -e "${Green}Device firmware updated. Restart may be needed.${Color_Off}\n"
        log_entry "firmware_updates" "info" "Device firmware updated" 
        ;;
    n|N )
        echo -e "${Yellow}Skipping firmware updates...${Color_Off}\n"
        ;;
    * )
        echo -e "${Red} Invalid option entered. ${Color_Off}\n"
        ;;
    esac
fi

log_entry "completed_fedora_system_updates" "info" "fedora_system_updates completed" 

read -r -p "Script completed. Would you like to reboot your device now? (y/n) " choice
case "$choice" in
y|Y )
    echo -e "${Green}Rebooting...${Color_Off}\n"
    sleep 5
    reboot
    ;;
n|N )
    echo -e "${Yellow}Skipping reboot and exiting...${Color_Off}\n"
    sleep 5
    ;;
* )
    echo -e "${Red} Invalid option entered. Skipping reboot... ${Color_Off}\n"
    sleep 5
    ;;
esac
