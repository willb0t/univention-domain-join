#!/bin/bash
set -e

echo "Starting the reset process for Ubuntu domain join..."

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Leave the domain using realm
echo "Leaving the domain..."
realm leave || echo "Not joined to a domain or realm leave failed."

# Stop and disable services
echo "Stopping and disabling services..."
systemctl stop sssd || echo "SSSD not running or failed to stop."
systemctl disable sssd || echo "SSSD not enabled or failed to disable."
systemctl stop autofs || echo "Autofs not running or failed to stop."
systemctl disable autofs || echo "Autofs not enabled or failed to disable."

# Remove SSSD configuration
echo "Removing SSSD configuration..."
rm -f /etc/sssd/sssd.conf
rm -f /etc/sssd/sssd.conf.bak

# Remove autofs configuration
echo "Removing autofs configuration..."
rm -f /etc/auto.master.d/home.autofs
rm -f /etc/auto.home

# Remove PAM mkhomedir configuration
echo "Removing PAM mkhomedir configuration..."
rm -f /usr/share/pam-configs/mkhomedir
pam-auth-update --force

# Remove LDAP configuration
echo "Removing LDAP configuration..."
rm -f /etc/ldap/ldap.conf
rm -f /etc/ldap.secret

# Remove Univention configuration
echo "Removing Univention configuration..."
rm -rf /etc/univention

# Clean up Kerberos tickets and configuration
echo "Cleaning up Kerberos..."
kdestroy -A || echo "No Kerberos tickets to destroy."
rm -f /etc/krb5.keytab

# Remove the NFS home directory (optional - uncomment if you want to remove it)
echo "NOTE: The /nfs/home directory is NOT being removed to preserve any user data."
echo "If you want to remove it, run: rm -rf /nfs/home"

# Restart NSS services
echo "Restarting NSS services..."
nscd -i passwd || echo "NSCD not installed or failed to invalidate cache."
nscd -i group || echo "NSCD not installed or failed to invalidate cache."

echo "Reset completed. You may need to reboot the system for all changes to take effect."
echo "To completely remove all installed packages, you can run:"
echo "apt purge realmd libnss-sss libpam-sss sssd sssd-tools adcli samba-common-bin oddjob oddjob-mkhomedir packagekit nfs-common autofs"

read -r -p "Do you want to reboot now? [y/N] " rebootnow
if [[ "$rebootnow" =~ ^([yY][eE][sS]|[yY])+$ ]]
then
    echo "Rebooting!"
    reboot
else
    echo "Reboot skipped. Some changes may not take effect until you reboot."
fi
