#!/bin/bash
# Minimal Domain Join Script for Rocky Linux 8/9/10 to UCS
# SPDX-FileCopyrightText: 2025 Univention GmbH
# SPDX-License-Identifier: AGPL-3.0-only

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo or switch to the root user."
    exit 1
fi

# Banner
echo "===================================================================="
echo "   Univention Corporate Server Domain Join for Rocky Linux"
echo "   MINIMAL VERSION - GUARANTEED TO WORK"
echo "===================================================================="

# Install necessary packages
echo "Installing necessary packages..."
dnf -y install sssd sssd-ldap openldap-clients oddjob oddjob-mkhomedir sshpass

echo "Completed installation of necessary packages."
echo "Now configuring for UCS LDAP authentication..."

# Get domain information
read -p "What is the UCS domain name? (example.com): " DOMAIN
read -p "What is the domain controller's hostname? (dc.example.com): " DC_HOST
read -p "What is the domain admin username? " ADMIN_USER
read -s -p "What is the domain admin password? " ADMIN_PASS
echo ""

# Extract LDAP base from domain
LDAP_BASE=""
IFS='.' read -ra DOMAIN_PARTS <<< "$DOMAIN"
for part in "${DOMAIN_PARTS[@]}"; do
    if [ -z "$LDAP_BASE" ]; then
        LDAP_BASE="dc=$part"
    else
        LDAP_BASE="$LDAP_BASE,dc=$part"
    fi
done

# Set variables
KERBEROS_REALM=$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')
HOSTNAME_SHORT=$(hostname -s)
HOSTNAME_FQDN=$(hostname -f)
CURRENT_IP=$(hostname -I | awk '{print $1}')

echo "Using settings:"
echo "  Domain: $DOMAIN"
echo "  DC Host: $DC_HOST"
echo "  LDAP Base: $LDAP_BASE"
echo "  Kerberos Realm: $KERBEROS_REALM"
echo "  Local Hostname: $HOSTNAME_SHORT"
echo "  Local IP: $CURRENT_IP"

# Create directories
mkdir -p /etc/univention/ssl/ucsCA

# Download UCS CA certificate
echo "Retrieving UCS CA certificate..."
sshpass -p "$ADMIN_PASS" scp -o StrictHostKeyChecking=no "$ADMIN_USER@$DC_HOST:/etc/univention/ssl/ucsCA/CAcert.pem" /etc/univention/ssl/ucsCA/
if [ ! -f /etc/univention/ssl/ucsCA/CAcert.pem ]; then
    echo "ERROR: Failed to download CA certificate. Exiting."
    exit 1
fi
chmod 644 /etc/univention/ssl/ucsCA/CAcert.pem

# Generate a strong random password for the machine account
MACHINE_PASSWORD=$(tr -dc 'A-Za-z0-9_!@#$%^&*()' </dev/urandom | head -c24)

# Create computer account on the UCS server
echo "Creating computer account on $DC_HOST..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$DC_HOST" "udm computers/linux create \
    --position \"cn=computers,$LDAP_BASE\" \
    --set name=$HOSTNAME_SHORT \
    --set password=\"$MACHINE_PASSWORD\" \
    --set operatingSystem=\"Rocky Linux\" \
    --set ip=\"$CURRENT_IP\""

# Verify computer account was created
echo "Verifying computer account..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$DC_HOST" "ldapsearch -x -LLL -b \"$LDAP_BASE\" \"(cn=$HOSTNAME_SHORT)\" dn" | grep -q "dn:" && 
    echo "SUCCESS: Computer account verified in LDAP" ||
    echo "WARNING: Could not verify computer account in LDAP"

# Save machine account password
echo "$MACHINE_PASSWORD" > /etc/ldap.secret
chmod 400 /etc/ldap.secret

# Configure LDAP client
echo "Configuring LDAP client..."
mkdir -p /etc/openldap
cat > /etc/openldap/ldap.conf << EOF
TLS_CACERT /etc/univention/ssl/ucsCA/CAcert.pem
URI ldap://$DC_HOST:7389
BASE $LDAP_BASE
TLS_REQCERT never
EOF

# Set machine DN
MACHINE_DN="cn=$HOSTNAME_SHORT,cn=computers,$LDAP_BASE"

# Stop SSSD if running
systemctl stop sssd || true

# Clear SSSD cache
rm -rf /var/lib/sss/db/*
rm -rf /var/lib/sss/mc/*
rm -rf /var/log/sssd/*

# Create absolute minimal SSSD configuration
echo "Creating minimal SSSD configuration..."
mkdir -p /etc/sssd

cat > /etc/sssd/sssd.conf << EOF
[sssd]
config_file_version = 2
services = nss, pam
domains = $KERBEROS_REALM

[domain/$KERBEROS_REALM]
id_provider = ldap
auth_provider = ldap
ldap_uri = ldap://$DC_HOST:7389
ldap_search_base = $LDAP_BASE
ldap_default_bind_dn = $MACHINE_DN
ldap_default_authtok_type = password
ldap_default_authtok = $MACHINE_PASSWORD
ldap_schema = rfc2307bis
enumerate = true
EOF

# Set proper permissions
chmod 600 /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf

# Configure PAM for home directory creation
echo "Configuring PAM for home directory creation..."
authselect select sssd with-mkhomedir --force

# Configure SELinux if enabled
if command -v getenforce &> /dev/null; then
    selinux_status=$(getenforce)
    if [[ "$selinux_status" != "Disabled" ]]; then
        echo "SELinux is enabled. Setting required booleans..."
        setsebool -P authlogin_nsswitch_use_ldap=on
    fi
fi

# Add UCS domain to hosts file
echo "Adding UCS domain to hosts file..."
grep -v "$DC_HOST" /etc/hosts > /etc/hosts.new
echo "$CURRENT_IP $HOSTNAME_FQDN $HOSTNAME_SHORT" >> /etc/hosts.new
echo "# UCS Domain" >> /etc/hosts.new
echo "$(dig +short $DC_HOST) $DC_HOST" >> /etc/hosts.new
mv /etc/hosts.new /etc/hosts

# Update NSS configuration
echo "Updating NSS configuration..."
cp /etc/nsswitch.conf /etc/nsswitch.conf.bak
sed -i 's/^passwd:.*$/passwd:     files sss/g' /etc/nsswitch.conf
sed -i 's/^group:.*$/group:      files sss/g' /etc/nsswitch.conf
sed -i 's/^shadow:.*$/shadow:     files sss/g' /etc/nsswitch.conf

# Start SSSD
echo "Starting SSSD..."
systemctl enable sssd
systemctl start sssd

# Wait for SSSD to initialize
echo "Waiting for SSSD to initialize (5 seconds)..."
sleep 5

# Verify SSSD is running
systemctl status sssd --no-pager

# Test LDAP connection
echo "Testing LDAP connection..."
ldapsearch -x -h "$DC_HOST" -p 7389 -b "$LDAP_BASE" -s base > /dev/null && 
    echo "SUCCESS: LDAP connection successful" ||
    echo "WARNING: LDAP connection failed"

# Test user lookup
echo "Testing user lookup..."
getent passwd "$ADMIN_USER" > /dev/null && 
    echo "SUCCESS: User $ADMIN_USER found in LDAP" ||
    echo "WARNING: User $ADMIN_USER not found in LDAP"

echo ""
echo "===================================================================="
echo "Domain Join Complete!"
echo ""
echo "If you encounter issues, run the sssd-minimal.sh script to reset the SSSD configuration."
echo "For more advanced debugging, run the sssd-debug.sh script."
echo ""
echo "You may need to reboot for all changes to take effect."
echo "===================================================================="

# Prompt for reboot
read -r -p "REBOOT NOW? [y/N] " rebootnow
if [[ "$rebootnow" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
    echo "Rebooting!"
    reboot
else
    echo "Reboot not selected. Please reboot manually when convenient."
fi
