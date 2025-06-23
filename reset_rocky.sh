#!/bin/bash
# Script for removing Univention domain join settings from Rocky Linux
# This script will reset all LDAP and Univention configurations

# Check if running on Rocky Linux
if [ -f /etc/rocky-release ]; then
    DISTRO="rocky"
    echo "Rocky Linux detected"
else
    echo "This script is intended for Rocky Linux. Exiting."
    exit 1
fi

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo or switch to the root user."
    exit 1
fi

echo "This script will remove all Univention domain join settings from this system."
echo "WARNING: This will remove all domain authentication capabilities!"
read -p "Are you sure you want to continue? (y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Operation cancelled."
    exit 0
fi

echo "===== Stopping and disabling SSSD service ====="
systemctl stop sssd
systemctl disable sssd
echo "SSSD service stopped and disabled."

echo "===== Removing SSSD configuration files ====="
rm -rf /etc/sssd/*
echo "SSSD configuration files removed."

echo "===== Removing LDAP configuration files ====="
rm -f /etc/openldap/ldap.conf
rm -f /etc/machine.secret
echo "LDAP configuration files removed."

echo "===== Removing Univention certificates and configuration ====="
rm -rf /etc/univention
echo "Univention certificates and configuration removed."

echo "===== Resetting PAM configuration ====="
# Use authselect to reset PAM configuration to default
authselect select sssd --force
echo "PAM configuration reset."

echo "===== Resetting SELinux settings ====="
# Reset SELinux booleans related to LDAP
if command -v setsebool &> /dev/null; then
    setsebool -P authlogin_nsswitch_use_ldap=off
    echo "SELinux settings reset."
fi

echo "===== Cleaning up system cache ====="
# Clear SSSD cache
rm -rf /var/lib/sss/db/*
rm -rf /var/lib/sss/mc/*
rm -rf /var/log/sssd/*
echo "System cache cleaned."

# Optionally remove installed packages
read -p "Do you want to remove installed packages (sssd, openldap-clients, etc.)? (y/n): " remove_pkgs
if [[ "$remove_pkgs" == "y" || "$remove_pkgs" == "Y" ]]; then
    echo "===== Removing installed packages ====="
    dnf -y remove sssd sssd-ldap sssd-tools openldap-clients oddjob-mkhomedir
    echo "Packages removed."
fi

echo "===== Reset complete ====="
echo "All Univention domain join settings have been removed."
echo "You may need to reboot the system for all changes to take effect."

# Prompt for reboot
read -r -p "REBOOT NOW? [y/N] " rebootnow
if [[ "$rebootnow" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
    echo "Rebooting!"
    reboot
else
    echo "Reboot not selected. Please reboot manually when convenient."
fi
