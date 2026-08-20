#!/bin/bash

set -e -o pipefail

# Colours
FLASHING_RED="\x1b[1;5;39;41m"
SOLID_GREEN="\x1b[32m"
SOLID_YELLOW="\x1b[33m"
COLOUR_RESET="\x1b[0m"

log_entry() {
  local action="$1"
  local status="$2"
  local msg="$3"
  logger -p user."${status}" -t "${action}" "fedora_luks_tpm: ${msg}"
}

# Make sure file is run as a root.
if [ "$EUID" -ne 0 ]; then
    echo -e "fedora_luks_tpm requires ${SOLID_YELLOW}root access${COLOUR_RESET}. You'll be prompted to enter your password, typing will be hidden."
    exec sudo "$0" "$@"
fi

# 1. Verify TPM presence
echo "Checking for TPM device..."
TPM_LIST=$(systemd-cryptenroll --tpm2-device=list)
if ! echo "$TPM_LIST" | grep -q '/dev/tpm'; then
    echo -e "$FLASHING_RED" "Error: No TPM device found." "$COLOUR_RESET" "Exiting."
    log_entry "tpm_check" "err" "TPM2.0 chip was not detected."
    sleep 5
    exit 1
else
    echo -e "$SOLID_GREEN" "TPM device found." "$COLOUR_RESET" "Proceeding..."
    log_entry "tpm_check" "info" "TPM2.0 chip was detected successfully."
fi

# 2. Check SecureBoot status
echo "Checking SecureBoot status..."
SB_STATE=$(mokutil --sb-state | grep -i 'SecureBoot' | awk '{print $2}')
if [ "$SB_STATE" != "enabled" ]; then
    echo -e "$FLASHING_RED" "Error: SecureBoot is not enabled." "$COLOUR_RESET"
    echo -e "Run the action 'Enable Secure Boot' from the F-menu first before re-running this script. "
    log_entry "secure_boot_check" "err" "SecureBoot is not enabled."
    sleep 5
    exit 1
else
    echo -e "$SOLID_GREEN" "SecureBoot is enabled.""$COLOUR_RESET" "Proceeding..."
    log_entry "secure_boot_check" "info" "SecureBoot is enabled."
fi

# 3. Find and select LUKS encrypted volume
echo "Finding LUKS volumes..."
LUKS_DEVICE=$(blkid -t TYPE=crypto_LUKS | head -n1 | cut -d: -f1)
if [ -z "$LUKS_DEVICE" ]; then
    echo -e "$FLASHING_RED" "Error: No LUKS device found." "$COLOUR_RESET" "Exiting."
    log_entry "locate_luks_drive" "err" "No LUKS device found."
    sleep 5
    exit 1
fi
echo -e "$SOLID_GREEN" "Selected LUKS device:" "$COLOUR_RESET" "$LUKS_DEVICE"
log_entry "locate_luks_drive" "info" "Selected LUKS device $LUKS_DEVICE."

# Check here if we have tpm2 enrolled already and just perform the re-enrolment steps
if systemd-cryptenroll "$LUKS_DEVICE" | grep -q 'tpm2'; then
   echo -e "$SOLID_YELLOW" "TPM is already configured to unlock LUKS.""$COLOUR_RESET" "Reconfiguring..."
   log_entry "already_enrolled" "warn" "TPM is already configured to unlock LUKS. Reconfiguring..."
   systemd-cryptenroll "$LUKS_DEVICE" --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=1,3,5,7,12
   sudo dracut -f
   echo -e "$SOLID_YELLOW" "Verifying TPM enrollment..." "$COLOUR_RESET"
   systemd-cryptenroll "$LUKS_DEVICE"
   log_entry "already_enrolled" "info" "Already enrolled so TPM unlock was reconfigured."
   read -n 1 -s -r -p "Press any key to exit"
   exit
fi

# 4. Enroll TPM2 for LUKS device with custom PCRs
echo -e "$SOLID_YELLOW" "Enrolling TPM2 for $LUKS_DEVICE with PCRs 1,3,5,7,12..." "$COLOUR_RESET"
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=1,3,5,7,12 "$LUKS_DEVICE"
log_entry "cryptenroll_action" "info" "TPM enrollement was completed."

# 5. Update /etc/crypttab to use the TPM as an unlock option
echo -e "$SOLID_YELLOW" "Updating /etc/crypttab..." "$COLOUR_RESET"
UUID=$(blkid -s UUID -o value "$LUKS_DEVICE")
echo "luks-$UUID UUID=$UUID none tpm2-device=auto,luks,discard" | sudo tee -a /etc/crypttab

# 6 & 7. Update GRUB config using grubby if available, else fallback to manual edit and rebuild
if command -v grubby &> /dev/null; then
    echo -e "$SOLID_GREEN" "grubby found." "$COLOUR_RESET" "Updating kernel args with grubby..."
    sudo grubby --update-kernel=ALL --args="rd.luks.options=tpm2-device=auto"
else
    echo -e "$SOLID_YELLOW" "grubby not found." "$COLOUR_RESET" "Editing /etc/default/grub and rebuilding GRUB config..."
    log_entry "grub_boot" "warn" "Grubby not found. Editing grub arguments manually and rebuilding initramfs."
    sudo sed -i '/^GRUB_CMDLINE_LINUX=/ s/"$/ rd.luks.options=tpm2-device=auto"/' /etc/default/grub

    if [ -f /boot/grub2/grub.conf ]; then
        echo -e "$SOLID_YELLOW" "Rebuilding GRUB config for Fedora 41+..." "$COLOUR_RESET"
        sudo grub2-mkconfig -o /boot/grub2/grub.conf
    else
        echo -e "$SOLID_YELLOW" "Rebuilding GRUB config for Fedora 40 or below..." "$COLOUR_RESET"
        sudo grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
    fi
fi
log_entry "grub_boot" "info" "crypttab and grub updated successfully."

# 8. (Optional) Enroll a recovery key
echo "Enrolling recovery key for $LUKS_DEVICE..."
systemd-cryptenroll --recovery-key "$LUKS_DEVICE"
log_entry "cryptenroll_recovery_key" "info" "Recovery key created successfully."

# 9. Rebuild initramfs
echo -e "$SOLID_YELLOW" "Rebuilding initramfs..." "$COLOUR_RESET"
sudo dracut -f

# 10. Verify enrollment
# TODO Add logger info here
echo -e "$SOLID_YELLOW" "Verifying TPM enrollment..." "$COLOUR_RESET"
systemd-cryptenroll "$LUKS_DEVICE"

echo -e "$SOLID_GREEN" "Done!" "$COLOUR_RESET" "You can now reboot and your TPM should unlock your encrypted drive."
log_entry "all_steps_completed" "info" "Fedora TPM LUKS script completed successfully."
read -n 1 -s -r -p "Press any key to exit"
