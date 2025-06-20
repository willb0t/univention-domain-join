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

# Create computer account on the UCS server with proper DNS registration
echo "Creating computer account on $FQDN_DC UCS server..."
HOSTNAME_SHORT=$(hostname -s)
HOSTNAME_FQDN=$(hostname -f)
CURRENT_IP=$(hostname -I | awk '{print $1}')

# More robust computer creation with DNS entries and verification
set -e  # Exit on error
sshpass -p "$REALMADMINPASS" ssh $ssh_options -n $REALMADMIN@$FQDN_DC bash << EOF
# Create computer account
udm computers/linux create \
    --position "cn=computers,${ldap_base}" \
    --set name=${HOSTNAME_SHORT} \
    --set password="${password}" \
    --set operatingSystem="Rocky Linux" \
    --set operatingSystemVersion="$ROCKY_VERSION" \
    --set description="Rocky Linux $ROCKY_VERSION joined on $(date)" \
    --set ip="${CURRENT_IP}"

# Verify computer was created
echo "Verifying computer account creation..."
udm computers/linux list --filter uid=${HOSTNAME_SHORT}

# Add forward DNS entry
echo "Creating DNS forward record for ${HOSTNAME_FQDN}..."
udm dns/forward_zone list | grep "zone:" | head -1
DOMAIN_ZONE=\$(udm dns/forward_zone list | grep "zone:" | head -1 | awk '{print \$2}')
if [ -n "\$DOMAIN_ZONE" ]; then
    udm dns/host_record create \
        --superordinate "zoneName=\$DOMAIN_ZONE,cn=dns,\$ldap_base" \
        --set name=${HOSTNAME_SHORT} \
        --set ip=${CURRENT_IP} \
        || echo "DNS forward record creation failed, may already exist"
else
    echo "WARNING: Could not determine DNS zone for forward record"
fi

# Add reverse DNS entry
echo "Creating DNS reverse record..."
IP_REVERSE=\$(echo ${CURRENT_IP} | awk -F. '{print \$3"."\$2"."$1}')
udm dns/reverse_zone list | grep "subnet:" | head -1
if udm dns/reverse_zone list | grep -q "subnet:"; then
    REVERSE_ZONE=\$(udm dns/reverse_zone list | grep "subnet:" | head -1 | awk '{print \$2}')
    if [ -n "\$REVERSE_ZONE" ]; then
        LAST_OCTET=\$(echo ${CURRENT_IP} | awk -F. '{print \$4}')
        udm dns/ptr_record create \
            --superordinate "zoneName=\$REVERSE_ZONE,cn=dns,\$ldap_base" \
            --set address="\$LAST_OCTET" \
            --set ptr_record=${HOSTNAME_FQDN}. \
            || echo "DNS reverse record creation failed, may already exist"
    else
        echo "WARNING: Could not determine reverse zone for PTR record"
    fi
else
    echo "WARNING: No reverse zone found for creating PTR record"
fi
EOF
set +e

# Verify LDAP entry was created
echo "Verifying computer account in LDAP..."
sshpass -p "$REALMADMINPASS" ssh $ssh_options -n $REALMADMIN@$FQDN_DC ldapsearch -x -LLL -b "${ldap_base}" "(uid=${HOSTNAME_SHORT})" dn | grep -q "dn:" && 
    echo "SUCCESS: Computer account verified in LDAP" ||
    echo "WARNING: Could not verify computer account in LDAP"

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

# Configure SSSD with minimal configuration to ensure it works
echo "Configuring SSSD with minimal settings..."
mkdir -p /etc/sssd
cat > /etc/sssd/sssd.conf << EOF
[sssd]
config_file_version = 2
services = nss, pam
domains = $kerberos_realm

[nss]
filter_users = root,nobody,halt,sync,shutdown,operator
filter_groups = root

[pam]
reconnection_retries = 3

[domain/$kerberos_realm]
id_provider = ldap
auth_provider = ldap
ldap_uri = ldap://$ldap_master:7389
ldap_search_base = $ldap_base
ldap_tls_reqcert = never
ldap_tls_cacert = /etc/univention/ssl/ucsCA/CAcert.pem
ldap_default_bind_dn = $machine_dn
ldap_default_authtok_type = password
ldap_default_authtok = $password
ldap_schema = rfc2307bis
ldap_user_name = uid
ldap_group_member = uniqueMember
enumerate = true
cache_credentials = true
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
# Backup hosts file
cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d%H%M%S)

# Remove existing entries for the UCS domain if they exist
sed -i '/# UCS Domain/d' /etc/hosts
sed -i "/$ldap_master/d" /etc/hosts

# Add fresh entries
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

# 1. Test hostname resolution
echo "Testing hostname resolution..."
ping -c 1 $ldap_master && echo "SUCCESS: Can reach UCS master server" || echo "WARNING: Cannot reach UCS master server"

# 2. Test LDAP connectivity
echo "Testing LDAP connectivity..."
ldapsearch -x -h $ldap_master -p 7389 -b "$ldap_base" -s base &>/dev/null && 
    echo "SUCCESS: LDAP connection to UCS server works" || 
    echo "WARNING: LDAP connection to UCS server failed"

# 3. Test user authentication
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
        
        # Try a different approach - list some users from LDAP
        echo "Trying to list some LDAP users..."
        getent passwd | grep -v "^root\|nobody\|nfsnobody" | head -5
    fi
fi

# 4. Test our computer account in LDAP
echo "Testing our computer account in LDAP..."
HOSTNAME_SHORT=$(hostname -s)
getent passwd | grep -q "$HOSTNAME_SHORT" && 
    echo "SUCCESS: Found our computer account in LDAP passwd database" || 
    echo "WARNING: Could not find our computer account in LDAP passwd database"

# 5. SSSD status check
echo "Checking SSSD service status..."
systemctl status sssd --no-pager || echo "SSSD service is not running correctly"

# Add SSSD debug info
echo ""
echo "If you encounter SSSD issues, you can enable debug mode with:"
echo "  1. Edit /etc/sssd/sssd.conf and add: debug_level = 9"
echo "  2. Restart SSSD: systemctl restart sssd"
echo "  3. Check logs: tail -f /var/log/sssd/sssd_$kerberos_realm.log"
echo ""
echo "Or run the provided debugging script: ./sssd-debug.sh"

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
