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
  logger -p user."${status}" -t "${action}" "fedora_secure_boot: ${msg}"
}

# Writing action output to cpe_logger
current_time=$(/bin/date +"%Y-%m-%d %T %z")
echo "$current_time; type: fedora_system_updates; action: started_dnf_updates; status: success; msg:  operating system updates started; " >> /var/log/cpe_logger.log

# Run system updates
echo -e "${Yellow}Running operating system updates...${Color_Off}\n"
dnf -y upgrade --refresh --skip-unavailable --disable-repo=cpe-yum*
if [ $? -ne 0 ] && [ $? -ne 1 ]; then
    echo -e "${Red}ERROR${Color_Off}: dnf upgrade failed (exit code $?)."
    # Writing action output to cpe_logger
    current_time=$(/bin/date +"%Y-%m-%d %T %z")
    echo "$current_time; type: fedora_system_updates; action: completed_dnf_updates; status: fail; msg:  operating system updates failed; " >> /var/log/cpe_logger.log
    exit 1
fi
echo -e "${Green}operating system updates completed.${Color_Off}\n"

# Writing action output to cpe_logger
current_time=$(/bin/date +"%Y-%m-%d %T %z")
echo "$current_time; type: fedora_system_updates; action: completed_dnf_updates; status: success; msg: operating system updates completed; " >> /var/log/cpe_logger.log

# Update flatpaks
if command -v flatpak >/dev/null 2>&1
then
    read -r -p "Would you like to update your flatpak applications? (y/n) " choice
    case "$choice" in
    y|Y )
        echo -e "${Yellow}Updating flatpak apps...${Color_Off}\n"
        flatpak update -y
        echo -e "${Green}flatpak apps updated.${Color_Off}\n"
        # Writing action output to cpe_logger
        current_time=$(/bin/date +"%Y-%m-%d %T %z")
        echo "$current_time; type: fedora_system_updates; action: flatpak_updates; status: success; msg: flatpak apps updated; " >> /var/log/cpe_logger.log
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
        # Writing action output to cpe_logger
        current_time=$(/bin/date +"%Y-%m-%d %T %z")
        echo "$current_time; type: fedora_system_updates; action: firmware_updates; status: success; msg: Device firmware updated; " >> /var/log/cpe_logger.log
        ;;
    n|N )
        echo -e "${Yellow}Skipping firmware updates...${Color_Off}\n"
        ;;
    * )
        echo -e "${Red} Invalid option entered. ${Color_Off}\n"
        ;;
    esac
fi

# Writing action output to cpe_logger
current_time=$(/bin/date +"%Y-%m-%d %T %z")
echo "$current_time; type: fedora_system_updates; action: completed_fedora_system_updates; status: success; msg: fedora_system_updates completed; " >> /var/log/cpe_logger.log

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
