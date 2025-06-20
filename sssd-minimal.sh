#!/bin/bash
# Minimal SSSD Configuration Script for Rocky Linux UCS Domain Join
# SPDX-FileCopyrightText: 2025 Univention GmbH
# SPDX-License-Identifier: AGPL-3.0-only

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo or switch to the root user."
    exit 1
fi

# Banner
echo "===================================================================="
echo "   MINIMAL SSSD Configuration for Univention Domain Join"
echo "   For Rocky Linux 8/9/10"
echo "===================================================================="

# Get domain information from existing configuration or prompt user
echo "Gathering domain information..."

# Try to get domain from existing configuration
if [ -f /etc/univention/ucr_master ]; then
    source /etc/univention/ucr_master
    ldap_master=${ldap_master}
    ldap_base=${ldap_base}
    kerberos_realm=${kerberos_realm}
    echo "Found UCS configuration:"
    echo "  LDAP Master: $ldap_master"
    echo "  LDAP Base: $ldap_base"
    echo "  Kerberos Realm: $kerberos_realm"
else
    # Prompt for required information
    read -p "UCS domain controller hostname: " ldap_master
    read -p "LDAP base DN (e.g., dc=example,dc=com): " ldap_base
    read -p "Kerberos realm (e.g., EXAMPLE.COM): " kerberos_realm
    echo "Using provided information:"
    echo "  LDAP Master: $ldap_master"
    echo "  LDAP Base: $ldap_base"
    echo "  Kerberos Realm: $kerberos_realm"
fi

# Get hostname information
hostname_short=$(hostname -s)
machine_dn="cn=${hostname_short},cn=computers,${ldap_base}"
echo "Local hostname: $hostname_short"
echo "Machine DN: $machine_dn"

# Check for machine password
if [ -f /etc/ldap.secret ]; then
    ldap_password=$(cat /etc/ldap.secret)
    echo "Found machine password in /etc/ldap.secret"
else
    echo "WARNING: Machine password file /etc/ldap.secret not found."
    read -s -p "Please enter the machine account password manually: " ldap_password
    echo ""
    echo "$ldap_password" > /etc/ldap.secret
    chmod 400 /etc/ldap.secret
    echo "Created /etc/ldap.secret with provided password"
fi

# Completely stop SSSD
echo "Stopping SSSD service..."
systemctl stop sssd

# Remove all SSSD cache and database files
echo "Cleaning up SSSD cache and database files..."
rm -rf /var/lib/sss/db/*
rm -rf /var/lib/sss/mc/*
rm -rf /var/log/sssd/*

# Create bare minimum SSSD configuration
echo "Creating absolute minimal SSSD configuration..."
mkdir -p /etc/sssd

cat > /etc/sssd/sssd.conf << EOF
[sssd]
config_file_version = 2
services = nss, pam
domains = ${kerberos_realm}

[domain/${kerberos_realm}]
id_provider = ldap
auth_provider = ldap
ldap_uri = ldap://${ldap_master}:7389
ldap_search_base = ${ldap_base}
ldap_default_bind_dn = ${machine_dn}
ldap_default_authtok_type = password
ldap_default_authtok = ${ldap_password}
ldap_schema = rfc2307bis
enumerate = true
EOF

# Set proper permissions on SSSD config file
chmod 600 /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf
echo "Set permissions on /etc/sssd/sssd.conf to 600"

# Update NSS configuration
echo "Updating NSS configuration..."
if [ -f /etc/nsswitch.conf ]; then
    cp /etc/nsswitch.conf /etc/nsswitch.conf.bak.$(date +%Y%m%d%H%M%S)
    sed -i 's/^passwd:.*$/passwd:     files sss/g' /etc/nsswitch.conf
    sed -i 's/^group:.*$/group:      files sss/g' /etc/nsswitch.conf
    sed -i 's/^shadow:.*$/shadow:     files sss/g' /etc/nsswitch.conf
    echo "Updated /etc/nsswitch.conf"
fi

# Configure PAM for home directory creation
echo "Configuring PAM for home directory creation..."
if command -v authselect &> /dev/null; then
    authselect select sssd with-mkhomedir --force
    echo "Applied authselect profile: sssd with-mkhomedir"
else
    authconfig --enablesssd --enablesssdauth --enablemkhomedir --updateall
    echo "Applied authconfig settings"
fi

# Make sure certificate directory exists
if [ ! -d /etc/univention/ssl/ucsCA ]; then
    echo "Creating certificate directory..."
    mkdir -p /etc/univention/ssl/ucsCA
fi

# Verify LDAP certificate exists
if [ ! -f /etc/univention/ssl/ucsCA/CAcert.pem ]; then
    echo "WARNING: UCS certificate not found at /etc/univention/ssl/ucsCA/CAcert.pem"
    echo "  This is required for LDAP TLS connections"
    echo "  Please ensure the certificate is properly installed"
fi

# Start SSSD service
echo "Starting SSSD service..."
systemctl start sssd

# Wait for SSSD to initialize
echo "Waiting for SSSD to initialize (5 seconds)..."
sleep 5

# Check SSSD status
echo "Checking SSSD service status..."
systemctl status sssd --no-pager

# Test SSSD functionality
echo ""
echo "Testing SSSD functionality..."
echo "Attempting to list users from LDAP:"
getent passwd | grep -v "^root\|nobody\|nfsnobody" | head -3

# Display troubleshooting information
echo ""
echo "===================================================================="
echo "SSSD Minimal Configuration Complete!"
echo ""
echo "If SSSD is still not working, check these common issues:"
echo ""
echo "1. Verify connectivity to LDAP server:"
echo "   $ ldapsearch -x -h ${ldap_master} -p 7389 -b \"${ldap_base}\" -s base"
echo ""
echo "2. Verify machine account exists in LDAP:"
echo "   $ ldapsearch -x -h ${ldap_master} -p 7389 -b \"${ldap_base}\" \"(cn=${hostname_short})\""
echo ""
echo "3. Check for syntax errors in SSSD config:"
echo "   $ sssctl config-check"
echo ""
echo "4. Check SSSD logs:"
echo "   $ journalctl -xe -u sssd"
echo "   $ cat /var/log/sssd/sssd.log"
echo ""
echo "5. Check permissions on SSSD files:"
echo "   $ ls -la /etc/sssd/sssd.conf (should be -rw------- root:root)"
echo "   $ ls -la /etc/ldap.secret (should be -r-------- root:root)"
echo "===================================================================="

echo "Would you like to add debug logging to SSSD? (y/n)"
read -r enable_debug

if [[ "$enable_debug" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
    echo "Adding debug logging to SSSD..."
    cp /etc/sssd/sssd.conf /etc/sssd/sssd.conf.nodebug
    
    # Add debug level
    sed -i '/^\[sssd\]/a debug_level = 9' /etc/sssd/sssd.conf
    sed -i '/^\[domain\//a debug_level = 9' /etc/sssd/sssd.conf
    
    # Restart SSSD
    systemctl restart sssd
    
    echo "Debug logging enabled. Check logs at /var/log/sssd/"
    echo "You can revert to non-debug mode by running:"
    echo "  $ cp /etc/sssd/sssd.conf.nodebug /etc/sssd/sssd.conf && systemctl restart sssd"
fi
