#!/bin/bash
# Enhanced script for joining Rocky Linux 8/9/10 to UCS domain with improved group mapping
# SPDX-FileCopyrightText: 2025 Univention GmbH
# SPDX-License-Identifier: AGPL-3.0-only

# Detect Rocky Linux version
if [ -f /etc/rocky-release ]; then
    ROCKY_VERSION=$(cat /etc/rocky-release | grep -oP '[\d\.]+' | head -1 | cut -d. -f1)
    echo "Rocky Linux $ROCKY_VERSION detected"
    
    # Check if version is supported
    if [[ "$ROCKY_VERSION" != "8" && "$ROCKY_VERSION" != "9" && "$ROCKY_VERSION" != "10" ]]; then
        echo "WARNING: This script is optimized for Rocky Linux 8, 9, and 10."
        echo "Your version is $ROCKY_VERSION. Proceeding anyway, but some features may not work as expected."
    fi
else
    echo "This script is intended for Rocky Linux. Exiting."
    exit 1
fi

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo or switch to the root user."
    exit 1
fi

# Banner
echo "===================================================================="
echo "   Univention Corporate Server Domain Join for Rocky Linux $ROCKY_VERSION"
echo "   Enhanced with full LDAP group mapping support"
echo "===================================================================="

# Install necessary packages
echo "Installing necessary packages..."
dnf -y install sssd sssd-ldap sssd-tools openldap-clients oddjob oddjob-mkhomedir

clear
echo "Completed installation of necessary packages."
echo "Now configuring for UCS LDAP authentication..."

# Get domain information
read -p "What is the UCS domain? (dom.example.com)? " REALMAD
read -p "What is the domain controller's short hostname? ('dc' part of dc.dom.example.com)? " REALMDC
read -p "What is the domain admin username? " REALMADMIN
read -s -p "What is the domain admin password? " REALMADMINPASS
echo ""

# Set variables
FQDN_DC="$REALMDC.$REALMAD"
shorthost=${HOSTNAME%%.*}

# Create directories
mkdir -p /etc/univention
echo "Connecting to $FQDN_DC UCS server and pulling UCS configuration..."

# Use password-based authentication instead of interactive prompting
ssh_options="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Retrieve UCR variables from the server
sshpass -p "$REALMADMINPASS" ssh $ssh_options -n $REALMADMIN@$FQDN_DC 'ucr shell | grep -v ^hostname=' >/etc/univention/ucr_master
echo "master_ip=$FQDN_DC" >>/etc/univention/ucr_master
chmod 660 /etc/univention/ucr_master

# Source UCR variables
. /etc/univention/ucr_master

# Generate a strong random password for the machine account
password="$(tr -dc 'A-Za-z0-9_!@#$%^&*()' </dev/urandom | head -c24)"

# Create computer account on the UCS server
echo "Creating computer account on $FQDN_DC UCS server..."
sshpass -p "$REALMADMINPASS" ssh $ssh_options -n $REALMADMIN@$FQDN_DC udm computers/linux create \
    --position "cn=computers,${ldap_base}" \
    --set name=$(hostname) --set password="${password}" \
    --set operatingSystem="Rocky Linux" \
    --set operatingSystemVersion="$ROCKY_VERSION"

# Save machine account password
printf '%s' "$password" >/etc/ldap.secret
chmod 0400 /etc/ldap.secret

# Get UCS CA certificate
echo "Retrieving UCS CA certificate..."
mkdir -p /etc/univention/ssl/ucsCA
sshpass -p "$REALMADMINPASS" scp $ssh_options $REALMADMIN@$FQDN_DC:/etc/univention/ssl/ucsCA/CAcert.pem /etc/univention/ssl/ucsCA/

# Configure LDAP client
echo "Configuring LDAP client..."
mkdir -p /etc/openldap
cat > /etc/openldap/ldap.conf << EOF
TLS_CACERT /etc/univention/ssl/ucsCA/CAcert.pem
URI ldap://$ldap_master:7389
BASE $ldap_base
TLS_REQCERT never
EOF

# Get machine DN
machine_dn="cn=$(hostname),cn=computers,$ldap_base"

# Configure SSSD with enhanced group mapping
echo "Configuring SSSD with enhanced group mapping..."
mkdir -p /etc/sssd
cat > /etc/sssd/sssd.conf << EOF
[sssd]
config_file_version = 2
reconnection_retries = 3
sbus_timeout = 30
services = nss, pam, sudo
domains = $kerberos_realm
debug_level = 0

[nss]
reconnection_retries = 3
filter_users = root,nobody,halt,sync,shutdown,operator
filter_groups = root
debug_level = 0
override_homedir = /home/%u
override_shell = /bin/bash

[pam]
reconnection_retries = 3
debug_level = 0

[domain/$kerberos_realm]
debug_level = 0
id_provider = ldap
auth_provider = ldap
access_provider = ldap
chpass_provider = ldap

# LDAP connection settings
ldap_uri = ldap://$ldap_master:7389
ldap_search_base = $ldap_base
ldap_tls_reqcert = never
ldap_tls_cacert = /etc/univention/ssl/ucsCA/CAcert.pem
ldap_default_bind_dn = $machine_dn
ldap_default_authtok_type = password
ldap_default_authtok = $password

# Schema and attribute mapping settings
ldap_schema = rfc2307bis
ldap_group_member = uniqueMember
ldap_user_member_of = memberOf
ldap_user_gecos = displayName
ldap_user_uuid = entryUUID
ldap_group_uuid = entryUUID
ldap_user_object_class = posixAccount
ldap_group_object_class = posixGroup

# Group mapping improvements
ldap_group_search_base = $ldap_base
ldap_user_search_base = $ldap_base
ldap_group_name = cn
ldap_user_name = uid
ldap_account_expire_policy = shadow
ldap_access_order = filter
ldap_access_filter = (objectClass=posixAccount)

# Group nesting - essential for proper group mapping
ldap_group_nesting_level = 5
ldap_nested_groups = true
ldap_referrals = false

# Performance settings
enumerate = true
cache_credentials = true
entry_cache_timeout = 600
entry_cache_nowait_percentage = 75

# Create home directories on first login
fallback_homedir = /home/%u
default_shell = /bin/bash
use_fully_qualified_names = false
EOF

# Set proper permissions
chmod 600 /etc/sssd/sssd.conf

# Configure PAM for home directory creation
echo "Configuring PAM for home directory creation..."
if command -v authselect &> /dev/null; then
    # Rocky 8 and newer use authselect
    authselect select sssd with-mkhomedir --force
else
    # Fallback for older systems
    authconfig --enablesssd --enablesssdauth --enablemkhomedir --updateall
fi

# Configure SELinux to allow LDAP authentication
echo "Configuring SELinux..."
if command -v getenforce &> /dev/null; then
    selinux_status=$(getenforce)
    if [[ "$selinux_status" != "Disabled" ]]; then
        echo "SELinux is enabled. Setting required booleans..."
        setsebool -P authlogin_nsswitch_use_ldap=on
        setsebool -P use_samba_home_dirs=on
    fi
fi

# Add UCS domain to hosts file for faster resolution
echo "Adding UCS domain to hosts file..."
echo "# UCS Domain" >> /etc/hosts
echo "$ldap_master_ip $ldap_master" >> /etc/hosts

# Stop and disable any conflicting services
echo "Stopping and disabling conflicting services..."
systemctl stop nscd &>/dev/null || true
systemctl disable nscd &>/dev/null || true

# Restart and enable SSSD
echo "Restarting SSSD..."
systemctl restart sssd
systemctl enable sssd

# Update Name Service Switch configuration
echo "Updating NSS configuration..."
if [ -f /etc/nsswitch.conf ]; then
    # Backup the original nsswitch.conf
    cp /etc/nsswitch.conf /etc/nsswitch.conf.bak
    
    # Update the NSS configuration
    sed -i 's/^passwd:.*$/passwd:     files sss/g' /etc/nsswitch.conf
    sed -i 's/^group:.*$/group:      files sss/g' /etc/nsswitch.conf
    sed -i 's/^shadow:.*$/shadow:     files sss/g' /etc/nsswitch.conf
    
    # Add initgroups line if not present
    if ! grep -q "^initgroups:" /etc/nsswitch.conf; then
        echo "initgroups: files sss" >> /etc/nsswitch.conf
    else
        sed -i 's/^initgroups:.*$/initgroups: files sss/g' /etc/nsswitch.conf
    fi
fi

# Verify the configuration
echo "Verifying the configuration..."
if id -u "$REALMADMIN" &>/dev/null; then
    echo "WARNING: User $REALMADMIN already exists locally. LDAP user may be masked."
else
    echo "Testing LDAP user lookup for $REALMADMIN..."
    # Try to get user information
    if getent passwd "$REALMADMIN" &>/dev/null; then
        echo "SUCCESS: User $REALMADMIN found in LDAP!"
        
        # Display groups for the user to verify group mapping
        echo "Groups for $REALMADMIN:"
        id "$REALMADMIN" || echo "Could not retrieve groups (this may be normal during initial setup)"
    else
        echo "WARNING: User $REALMADMIN not found. This may be normal if the user doesn't exist in LDAP."
        echo "You can test with a known LDAP user after reboot."
    fi
fi

# Provide additional debug command info
echo ""
echo "===================================================================="
echo "UCS LDAP Domain Join Complete!"
echo ""
echo "Useful debug commands:"
echo "  - sssctl user-checks <username> - Check user access"
echo "  - getent passwd <username> - Verify user in NSS"
echo "  - getent group <groupname> - Verify group in NSS"
echo "  - id <username> - Show user's groups"
echo "  - tail -f /var/log/sssd/sssd_$kerberos_realm.log - View SSSD logs"
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
