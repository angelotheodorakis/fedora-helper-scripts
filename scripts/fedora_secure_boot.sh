#!/bin/bash

# NOTE
# This still will currently only work on Lenovo devices since it manages the secure boot attribute through thinklmi
# It will also start the MOK key enrollment of the akmod self-signing key to the BIOS which then need to be performed manually

# Bash text color
Color_Off='\033[0m' # Text Reset
Red='\033[1;91m'    # Red
Yellow='\033[1;93m' # Yellow
Green='\033[1;32m'  # Green

# Global variables
BIOS_ATTR_SB="/sys/class/firmware-attributes/thinklmi/attributes/SecureBoot/current_value"
BIOS_ATTR_3PCA="/sys/class/firmware-attributes/thinklmi/attributes/Allow3rdPartyUEFICA/current_value"
BIOS_ATTR_3PMSCA="/sys/class/firmware-attributes/thinklmi/attributes/AllowMicrosoft3rdPartyUEFICA/current_value"
ATTR_MODE="/sys/class/firmware-attributes/thinklmi/attributes/save_settings"
AKMODS_CERT="/etc/pki/akmods/certs/public_key.der"
# Check for Nvidia (reuse the logic from the installer script https://www.internalfb.com/code/fbsource/fbcode/cpe/linux/provisioning/nvidia_setup.sh)
HAS_NVIDIA_GPU=false
HAS_RPMFUSION_DRIVER=false
HAS_AKMODS_CERT=false

log_entry() {
  local action="$1"
  local status="$2"
  local msg="$3"
  logger -p user."${status}" -t "${action}" "fedora_secure_boot: ${msg}"
}

# Make sure file is run as a root.
if [ "$EUID" -ne 0 ]; then
    echo -e "fedora_secure_boot requires ${Yellow}root access${Color_Off}. You'll be prompted to enter your password, typing will be hidden. \n"
    exec sudo "$0" "$@"
fi

# check for Nvidia GPU
if /usr/sbin/lspci -mnn | grep -E 'VGA|3D controller' | grep NVIDIA | grep -q 10de; then
  HAS_NVIDIA_GPU=true
fi

# Check for rpmfusion driver
if [[ -n $(rpm -q kmod-nvidia-$(uname -r)) ]]; then
  HAS_RPMFUSION_DRIVER=true
fi

# Check for akmods
if [ -d "/etc/pki/akmods/certs" ] && [ -f "$AKMODS_CERT" ]; then
  HAS_AKMODS_CERT=true
fi

# Function for importing the akmods key
import_key () {
    echo -e "${Yellow} akmod key enrollment! ${Color_Off}\n"
    echo -e "We are going to import your akmod self-signing key now. You will be required to setup an import password. \n"
    echo -e "Upon reboot you will be asked to go through MOK enrollment to import the akmods key to the BIOS trusted certificate store. \n"
    echo -e "Refer to the wiki here for more info and a step by step of MOK enrollment if needed: https://fburl.com/akmods_signing. \n"
    max_attempts=3
    attempt=1
    success=0
    while [[ $attempt -le $max_attempts ]]; do
        mokutil --import "$AKMODS_CERT"
        # Check if mokutil -N is not empty (success)
        if [[ -n $(mokutil -N) ]]; then
            success=1
            break
        else
            echo -e "${Red}Something went wrong, did you set a password as prompted? Let's try again...${Color_Off} \n"
            ((attempt++))
        fi
    done
    if [[ $success -eq 1 ]]; then
        echo -e "${Green} akmod key enrollment started. Proceeding... ${Color_Off}\n"
        # Writing action output to logger
        log_entry "akmod_key_import" "success" "Akmod key enrollment started successfully."
    else
        echo -e "${Red}Failed to import akmod key after $max_attempts attempts. Exiting.${Color_Off}\n"
        echo -e "${Red} WARNING!${Color_Off}. Secure boot has been enabled but MOK enrollment was unsuccessful. There be dragons! Proceed with caution and disable Secure boot manually if needed so this script can retry.\n"
        # Writing action output to logger
        log_entry "akmod_key_import" "fail" "Akmod key enrollment failed after $max_attempts attempts."
        sleep 5
        exit 1
    fi
}

# Writing Script Starting action output to logger
log_entry "script_start" "success" "Secure Boot script started."

# Checking device make and model
MAKE=$(dmidecode -s system-manufacturer)
MODEL=$(dmidecode -s system-version)
if [[ $MAKE != "LENOVO" ]]; then
    echo -e "${Red}ERROR${Color_Off}: This script can only run on Lenovo Devices. \n"
    # Writing action output to logger
    log_entry "manufacturer_check" "fail" "Manufacturer not Lenovo, it's $MAKE and $MODEL instead."
    sleep 5
    exit 1
fi

# Check current state of secure boot and BIOS attribute
MOKUTIL_CHECK=$(mokutil --sb-state)
BIOS_ATTR_SB_STATE=$(cat "$BIOS_ATTR_SB")
if [ -e $BIOS_ATTR_3PCA ]; then
    BIOS_ATTR_3PCA_STATE=$(cat "$BIOS_ATTR_3PCA")
fi
if [ -e $BIOS_ATTR_3PMSCA ]; then
    BIOS_ATTR_3PCA_STATE=$(cat "$BIOS_ATTR_3PMSCA")
fi

if [[ $BIOS_ATTR_3PCA_STATE == *"Disable"* ]]; then
    echo -e "${Red}ERROR${Color_Off}: It appears the BIOS setting for ${Yellow}Microsoft 3rd Party UEFI CA's${Color_Off} on your device is currently disabled. \n"
    echo -e "If you enable Secure Boot without allowing Microsoft 3rd Party UEFI CA's your device will fail to boot Fedora on the next Reboot. \n"
    echo -e "For security reasons this setting cannot be modified by this script. \n"
    echo -e "You will need to manually enter your BIOS settings (Press F1 on boot) and enable 3rd Party CA's from ${Yellow}'Security - Secure Boot - Allow Microsoft 3rd Party UEFI CA'${Color_Off}. \n"
    echo -e "Once you enable this setting you can re-run this script to configure Secure Boot. \n"
    # Writing action output to logger
    log_entry "3pca_check" "fail" "3rd Party CA is currently disabled."
    read -n 1 -s -r -p "Press any key to exit."
    sleep 5
    exit 1
fi

# shellcheck disable=SC2235
if [[ $MOKUTIL_CHECK == "SecureBoot enabled" ]] && [[ $BIOS_ATTR_SB_STATE == "Enable" ]]; then
    echo -e "${Green}Secure Boot already Enabled.${Color_Off}. This script will now exit.\n"
    # Writing action output to logger
    log_entry "secure_boot_check" "success" "Secure Boot already Enabled."
    sleep 5
    exit 0
elif ([[ $MOKUTIL_CHECK == "SecureBoot disabled" ]] && [[ $BIOS_ATTR_SB_STATE == "Enable" ]]) ||
    ([[ $MOKUTIL_CHECK == "SecureBoot enabled" ]] && [[ $BIOS_ATTR == "Disable" ]]); then
    echo -e "${Red}ERROR${Color_Off}: Configuration inconsistency between mokutil and BIOS attributes. Please check your BIOS settings for 'Security - Secure boot' manually. \n"
    # Writing action output to logger
    log_entry "secure_boot_check" "fail" "Configuration inconsistency between mokutil and BIOS attributes."
    sleep 5
    exit 1
elif [[ $MOKUTIL_CHECK == "SecureBoot disabled" ]] && [[ $BIOS_ATTR_SB_STATE == "Disable" ]]; then
    echo -e "${Yellow}Secure Boot currently disabled.${Color_Off}. proceeding with configuration. \n"
    # Writing action output to logger
    log_entry "secure_boot_check" "success" "Secure Boot confirmed disabled. Proceeding to next step."
fi

# Prompt user to accept or defer enabling of secure boot
echo -e "This script will now attempt to configure secure boot. Please note that a reboot will be required for the change to take effect. \n"
echo -e "You can defer this for now if necessary and the script will try again tomorrow. Alternatively you can launch it at your convenience from the F-menu action 'Enable Secure Boot'. \n"
#TODO add date here with agreed timelines
echo -e "Please also note that you can only defer until XXXX, after this date the change will be completed automatically without prompting. \n"

read -r -p "Would you like to enable secure boot now? (y/n) " choice
case "$choice" in
y|Y )
    echo -e "${Yellow}Enabling secure boot.${Color_Off} \n"
    if [[ -n $BIOS_ATTR_3PCA ]]; then
        echo bulk > "$ATTR_MODE"
        echo Enable > "$BIOS_ATTR_3PCA"
    fi
    echo Enable > "$BIOS_ATTR_SB"
    #TODO Add a check if update succeeded here. Capture any errors from the command.
    if [ $? -ne 0 ]; then
        echo -e "${Red}ERROR${Color_Off}: Something went wrong changing the BIOS attribute: (exit code $?). \n"
        # Writing action output to logger
        log_entry "bios_attribute_update" "fail" "Something went wrong changing the BIOS attribute."
        sleep 5
        exit 1
    else
        echo -e "${Green}BIOS Attribute updated.${Color_Off} \n"
        # Writing action output to logger
        log_entry "bios_attribute_update" "success" "BIOS Attribute updated."
    fi
    ;;
* )
    echo -e "${Red}Skipping for now. Please re-run this script at your earliest convenience.${Color_Off} \n"
    # Writing action output to logger
    log_entry "bios_attribute_update" "warning" "Script deferred by user."
    sleep 5
    exit 0
    ;;
esac

if $HAS_NVIDIA_GPU && ! $HAS_RPMFUSION_DRIVER; then
    # prompt user they will need to enroll the self-signed Nvidia drivers key manually
    echo -e "${Yellow} Nvidia hardware detected but no rpmfusion akmod module for your running kernel ${Color_Off} \n"
    echo -e "You will need to handle kernel module signing manually for your installed Nvidia drivers. \n"
    # Writing action output to logger
    log_entry "nvidia_akmod_missing" "warning" "Nvidia hardware detected but no rpmfusion akmod module detected."
    exit 0
fi

if mokutil -t "$AKMODS_CERT" | grep "already enrolled"; then
    echo -e "${Green} akmods cert already enrolled ${Color_Off} \n"
    echo -e "You already have the key $AKMODS_CERT imported in your BIOS so it can be used to self-sign your 3rd party kernel modules. \n"
    if $HAS_NVIDIA_GPU && $HAS_AKMODS_CERT; then
        echo -e "Your Nvidia drivers from RPMfusion should now work as expected. If not, you might need to force akmods to rebuild them with `akmods --akmod nvidia`. \n"
    fi
    # Writing action output to logger
    log_entry "akmod_already_imported" "success" "akmod key already imported in the BIOS."
    read -n 1 -s -r -p "Press any key to reboot your device. "
    echo -e "\n ${Green}Rebooting...${Color_Off}\n"
    sleep 5
    reboot
fi

if $HAS_AKMODS_CERT; then
    # enroll the cert
    import_key
    akmods --rebuild
    dracut -f
    if $HAS_NVIDIA_GPU; then
        akmods_prompt="and the Nvidia driver rebuilt"
        akmods_logger="for_nvidia_"
        akmods_logger_prompt="to support Nvidia drivers"
        echo -e "${Green} Process complete and Nvidia driver kernel module was rebuilt. ${Color_Off}\n"
    else
        akmods_prompt="for any 3rd party kernel modules you use"
        echo -e "${Green} Process complete. ${Color_Off}\n"
    fi
    echo -e "${Yellow} CAUTION!: ${Color_Off} With secure boot now enabled ${akmods_prompt}, you absolutely need to complete MOK key enrollment, otherwise your device will be very unhappy.\n"
    # Writing action output to logger
    log_entry "akmod_${akmods_logger}imported" "success" "akmod key import started ${akmods_logger_prompt}."
    read -n 1 -s -r -p "Press any key to reboot your device and make sure you complete MOK enrollment! "
elif ! $HAS_NVIDIA_GPU && ! $HAS_AKMODS_CERT; then
    # Install dependencies (might need a try catch)
    dnf install -y kmodtool akmods mokutil openssl
    import_key
    echo -e "${Green} Process complete, akmods was installed and preconfigured. ${Color_Off}\n"
    echo -e "${Yellow} CAUTION!: ${Color_Off} With secure boot now enabled for any 3rd party kernel modules you might want to use, you absolutely need to complete MOK key enrollment, otherwise your device will be very unhappy.\n"
    # Writing action output to logger
    log_entry "akmod_installed_imported" "success" "akmod installed and key import started."
    read -n 1 -s -r -p "Press any key to reboot your device and make sure you complete MOK enrollment! "
else
    echo -e "${Red} Something went very wrong. ${Color_Off}\n"
    echo -e "Here be dragons. This is a state you should never have found yourself in. Ensure you understand the configuration of your BIOS for secure boot and 3rd party UEFI CAs, the Nvidia driver you are using (if any) "
    echo -e "and your self-signed MOK key state and enrollment to your device's BIOS."
    log_entry "akmod_import_failure" "fail" "unknown error and status of akmod enrollment and GPU state"
    read -n 1 -s -r -p "Press any key to exit."
    sleep 5
    exit 1
fi

echo -e "\n ${Green}Rebooting...${Color_Off}\n"
sleep 5
reboot

######################################################################################################
# Useful commands
# sudo keyctl list %:.platform # Lists all keys in BIOS keyring
# mokutil -l # list all user imported imported keys
# mokutil -N # list keys pending to be imported
# sudo mokutil -t /etc/pki/akmods/certs/public_key.der # validate if akmods key needs to be enrolled
######################################################################################################
