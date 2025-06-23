#!/bin/bash
# Script for joining Rocky Linux to UCS domain using LDAP authentication
# SPDX-FileCopyrightText: 2025 Univention GmbH
# SPDX-License-Identifier: AGPL-3.0-only

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

echo "Installing necessary packages..."
dnf -y install sssd sssd-ldap openldap-clients oddjob oddjob-mkhomedir

clear
echo "Completed installation of necessary packages."
echo "Now configuring for UCS LDAP authentication..."

read -p "What is the UCS domain? (dom.example.com)? " REALMAD
read -p "What is the domain controller's short hostname? ('dc' part of dc.dom.example.com)? " REALMDC
read -p "What is the domain admin username? " REALMADMIN
shorthost=${HOSTNAME%%.*}

mkdir -p /etc/univention
echo "Connecting to "$REALMDC.$REALMAD" UCS server and pulling UCS config. Password for domain admin will be prompted."
ssh -n root@$REALMDC.$REALMAD 'ucr shell | grep -v ^hostname=' >/etc/univention/ucr_master
echo "master_ip="$REALMDC.$REALMAD"" >>/etc/univention/ucr_master
chmod 660 /etc/univention/ucr_master

. /etc/univention/ucr_master

# Check if computer account already exists
echo "Checking if computer account already exists on "$REALMDC.$REALMAD" UCS server..."
hostname_short=$(hostname -s)
computer_exists=$(ssh -n root@$REALMDC.$REALMAD "udm computers/linux list --filter cn=$hostname_short | grep -c DN:")
computer_exists_with_dollar=$(ssh -n root@$REALMDC.$REALMAD "udm computers/linux list --filter cn=${hostname_short}\$ | grep -c DN:")

# Generate a random password
password="$(tr -dc A-Za-z0-9_ </dev/urandom | head -c20)"

if [ "$computer_exists" -gt 0 ] || [ "$computer_exists_with_dollar" -gt 0 ]; then
    echo "Computer account already exists. Updating password..."
    
    # Determine the correct DN to use
    if [ "$computer_exists" -gt 0 ]; then
        computer_dn=$(ssh -n root@$REALMDC.$REALMAD "udm computers/linux list --filter cn=$hostname_short | grep DN: | cut -d' ' -f2-")
    else
        computer_dn=$(ssh -n root@$REALMDC.$REALMAD "udm computers/linux list --filter cn=${hostname_short}\$ | grep DN: | cut -d' ' -f2-")
    fi
    
    # Update the existing computer account
    ssh -n root@$REALMDC.$REALMAD udm computers/linux modify \
        --dn "$computer_dn" \
        --set password="${password}" \
        --set operatingSystem="Rocky Linux" \
        --set operatingSystemVersion="$(cat /etc/rocky-release | grep -oP '[\d\.]+' | head -1)"
else
    # Create a new computer account
    echo "Creating new computer account on "$REALMDC.$REALMAD" UCS server..."
    ssh -n root@$REALMDC.$REALMAD udm computers/linux create \
        --position "cn=computers,${ldap_base}" \
        --set name="$hostname_short" \
        --set password="${password}" \
        --set operatingSystem="Rocky Linux" \
        --set operatingSystemVersion="$(cat /etc/rocky-release | grep -oP '[\d\.]+' | head -1)"
fi

# Save the password
printf '%s' "$password" >/etc/ldap.secret
chmod 0400 /etc/ldap.secret

# Get domain groups - try different filters to find appropriate groups
echo "Retrieving domain groups from UCS server..."
# First try Domain* groups
domain_groups=$(ssh -n root@$REALMDC.$REALMAD "udm groups/group list --filter cn=Domain* | grep DN: | cut -d' ' -f2-")

# If no Domain* groups found, try groups with "domain" in their name (case insensitive)
if [ -z "$domain_groups" ]; then
    echo "No Domain* groups found, trying alternative group search..."
    domain_groups=$(ssh -n root@$REALMDC.$REALMAD "udm groups/group list | grep -i domain | grep DN: | cut -d' ' -f2-")
fi

# If still no groups found, try to get all groups
if [ -z "$domain_groups" ]; then
    echo "No domain groups found, listing all available groups..."
    domain_groups=$(ssh -n root@$REALMDC.$REALMAD "udm groups/group list --filter objectClass=univentionGroup | grep DN: | cut -d' ' -f2-")
fi

# Add computer to domain groups
if [ -n "$domain_groups" ]; then
    echo "Adding computer to domain groups..."
    # Use the short hostname for consistency
    computer_cn="cn=${hostname_short},cn=computers,${ldap_base}"
    
    # Process each group DN
    echo "$domain_groups" | while read -r group_dn; do
        if [ -n "$group_dn" ]; then
            echo "Adding ${hostname_short} to group: $group_dn"
            # Add error handling for the group modification
            if ! ssh -n root@$REALMDC.$REALMAD udm groups/group modify \
                --dn "$group_dn" \
                --append hosts="$computer_cn"; then
                echo "Warning: Failed to add computer to group: $group_dn"
                echo "This is non-fatal, continuing with domain join..."
            fi
        fi
    done
else
    echo "Warning: No groups found to add the computer to."
    echo "This is non-fatal, continuing with domain join..."
fi

# Get UCS CA certificate
echo "Retrieving UCS CA certificate..."
mkdir -p /etc/univention/ssl/ucsCA
scp root@$REALMDC.$REALMAD:/etc/univention/ssl/ucsCA/CAcert.pem /etc/univention/ssl/ucsCA/

# Create ldap.conf
rm -f /etc/openldap/ldap.conf
mkdir -p /etc/openldap
echo "TLS_CACERT /etc/univention/ssl/ucsCA/CAcert.pem
URI ldap://$ldap_master:7389
BASE $ldap_base" > /etc/openldap/ldap.conf

# Get machine DN - use short hostname for consistency
echo "Getting machine DN..."
machine_dn="cn=${hostname_short},cn=computers,$ldap_base"

# Configure SSSD for LDAP authentication
echo "Configuring SSSD for LDAP authentication..."
mkdir -p /etc/sssd
cat > /etc/sssd/sssd.conf << EOF
[sssd]
config_file_version = 2
reconnection_retries = 3
sbus_timeout = 30
services = nss, pam, sudo
domains = $kerberos_realm

[nss]
reconnection_retries = 3
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

# User attribute mappings
ldap_user_object_class = posixAccount
ldap_user_name = uid
ldap_user_uid_number = uidNumber
ldap_user_gid_number = gidNumber
ldap_user_home_directory = homeDirectory
ldap_user_shell = loginShell
ldap_user_gecos = displayName
ldap_user_member_of = memberOf
ldap_user_uuid = entryUUID

# Group mappings
ldap_group_object_class = posixGroup
ldap_group_name = cn
ldap_group_gid_number = gidNumber
ldap_group_member = uniqueMember
ldap_group_uuid = entryUUID
ldap_group_search_base = $ldap_base
ldap_group_search_filter = (|(objectClass=posixGroup)(objectClass=univentionGroup)(objectClass=sambaGroupMapping))

# Enhanced group mapping
ldap_group_nesting_level = 5
ldap_initgroups_use_matching_rule_in_chain = True
ldap_user_principal = uid
ldap_group_member_of_user_attr = dn

# Machine account group membership
ldap_use_tokengroups = False

# ID mapping
ldap_id_mapping = False
ldap_idmap_autorid_compat = True

# Home directory configuration
fallback_homedir = /home/%u
default_shell = /bin/bash
# Uncomment the next line if you want to override all home directories
# override_homedir = /home/%u

cache_credentials = true
enumerate = true
EOF

chmod 600 /etc/sssd/sssd.conf

# Configure PAM for home directory creation
echo "Configuring PAM for home directory creation..."
authselect select sssd with-mkhomedir --force

# Configure SELinux to allow SSSD to access LDAP
echo "Configuring SELinux..."
setsebool -P authlogin_nsswitch_use_ldap=on

# Restart SSSD
echo "Restarting SSSD..."
systemctl restart sssd

# Enable SSSD to start at boot
systemctl enable sssd

echo "UCS LDAP Domain Join Complete!"
echo "You can now authenticate with domain users."
echo "Note: You may need to reboot for all changes to take effect."

# Prompt for reboot
read -r -p "REBOOT NOW? [y/N] " rebootnow
if [[ "$rebootnow" =~ ^([yY][eE][sS]|[yY])+$ ]]
then
    echo "Rebooting!"
    reboot
else
    echo "Reboot not selected. Please reboot manually when convenient."
fi
