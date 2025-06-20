#!/bin/bash
# SSSD Configuration Fix Script for Rocky Linux UCS Domain Join
# SPDX-FileCopyrightText: 2025 Univention GmbH
# SPDX-License-Identifier: AGPL-3.0-only

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo or switch to the root user."
    exit 1
fi

# Banner
echo "===================================================================="
echo "   SSSD Configuration Fix for Univention Domain Join"
echo "   For Rocky Linux 8/9/10"
echo "===================================================================="

# Backup current config if it exists
if [ -f /etc/sssd/sssd.conf ]; then
    echo "Backing up current SSSD configuration..."
    cp /etc/sssd/sssd.conf /etc/sssd/sssd.conf.bak.$(date +%Y%m%d%H%M%S)
fi

# Get domain information from existing configuration or prompt user
echo "Gathering domain information..."

# Try to get domain from existing configuration
if [ -f /etc/univention/ucr_master ]; then
    source /etc/univention/ucr_master
    ldap_master=${ldap_master}
    ldap_base=${ldap_base}
    kerberos_realm=${kerberos_realm}
else
    # Prompt for required information
    read -p "UCS domain controller hostname: " ldap_master
    read -p "LDAP base DN (e.g., dc=example,dc=com): " ldap_base
    read -p "Kerberos realm (e.g., EXAMPLE.COM): " kerberos_realm
fi

# Get hostname information
hostname_short=$(hostname -s)
machine_dn="cn=${hostname_short},cn=computers,${ldap_base}"

# Check if machine.secret exists
if [ ! -f /etc/ldap.secret ]; then
    echo "ERROR: Machine password file /etc/ldap.secret not found."
    echo "Please run the domain join script first to create the machine account."
    exit 1
fi

# Get machine password
ldap_password=$(cat /etc/ldap.secret)

# Create a minimal working SSSD configuration
echo "Creating a minimal SSSD configuration..."
cat > /etc/sssd/sssd.conf << EOF
[sssd]
config_file_version = 2
services = nss, pam
domains = ${kerberos_realm}

[nss]
filter_users = root,nobody,halt,sync,shutdown,operator
filter_groups = root

[pam]
reconnection_retries = 3

[domain/${kerberos_realm}]
id_provider = ldap
auth_provider = ldap
ldap_uri = ldap://${ldap_master}:7389
ldap_search_base = ${ldap_base}
ldap_tls_reqcert = never
ldap_tls_cacert = /etc/univention/ssl/ucsCA/CAcert.pem
ldap_default_bind_dn = ${machine_dn}
ldap_default_authtok_type = password
ldap_default_authtok = ${ldap_password}
ldap_schema = rfc2307bis
ldap_user_name = uid
ldap_group_member = uniqueMember
enumerate = true
cache_credentials = true
use_fully_qualified_names = false
EOF

# Set proper permissions on SSSD config file
chmod 600 /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf

# Update nsswitch.conf
echo "Updating NSS configuration..."
cp /etc/nsswitch.conf /etc/nsswitch.conf.bak.$(date +%Y%m%d%H%M%S)
sed -i 's/^passwd:.*$/passwd:     files sss/g' /etc/nsswitch.conf
sed -i 's/^group:.*$/group:      files sss/g' /etc/nsswitch.conf
sed -i 's/^shadow:.*$/shadow:     files sss/g' /etc/nsswitch.conf

# Stop SSSD if it's running
echo "Stopping SSSD service..."
systemctl stop sssd

# Clear SSSD cache
echo "Clearing SSSD cache..."
rm -rf /var/lib/sss/db/*
rm -rf /var/lib/sss/mc/*

# Start SSSD service
echo "Starting SSSD service..."
systemctl start sssd
systemctl status sssd

# Test SSSD functionality
echo "Testing SSSD functionality..."
echo "Listing LDAP users (should show some users if successful):"
getent passwd | grep -v "^root\|nobody\|nfsnobody" | head -5

echo ""
echo "===================================================================="
echo "SSSD Configuration Fix Complete!"
echo ""
echo "If SSSD is running, try testing user lookup with:"
echo "  getent passwd <username>"
echo ""
echo "If SSSD is still not running, check logs with:"
echo "  journalctl -xe -u sssd"
echo "  cat /var/log/sssd/sssd.log"
echo "===================================================================="
