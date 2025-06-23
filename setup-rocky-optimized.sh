#!/bin/bash
# Optimized script for joining Rocky Linux to UCS domain using LDAP authentication
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
dnf -y install sssd sssd-ldap openldap-clients oddjob oddjob-mkhomedir openssh-clients

clear
echo "Completed installation of necessary packages."
echo "Now configuring for UCS LDAP authentication..."

read -p "What is the UCS domain? (dom.example.com)? " REALMAD
read -p "What is the domain controller's short hostname? ('dc' part of dc.dom.example.com)? " REALMDC
read -p "What is the domain admin username? " REALMADMIN

# Get local hostname information
hostname_short=$(hostname -s)
rocky_version=$(cat /etc/rocky-release | grep -oP '[\d\.]+' | head -1)

# Generate a random password for the computer account
password="$(tr -dc A-Za-z0-9_ </dev/urandom | head -c20)"

# Set up SSH connection sharing to reduce the number of logins
SSH_CONTROL="/tmp/ssh_control_socket_$$"
SSH_CMD="ssh -o ControlPath=$SSH_CONTROL"
SSH_OPTS="-o ControlMaster=auto -o ControlPersist=yes"

echo "Setting up connection to $REALMDC.$REALMAD..."
$SSH_CMD $SSH_OPTS -M -N root@$REALMDC.$REALMAD &
SSH_PID=$!

# Wait for the control socket to be created
sleep 2

# Create a temporary directory for our helper scripts
mkdir -p /tmp/ucs_join_helper

# Create a helper script on the UCS server to perform multiple operations
echo "Creating helper script on UCS server..."
cat > /tmp/ucs_join_helper/domain_join_helper.sh << 'EOF'
#!/bin/bash
# Helper script to perform multiple operations on UCS server

# Parameters
HOSTNAME="$1"
PASSWORD="$2"
ROCKY_VERSION="$3"

# Get UCR variables
echo "# UCR Variables" > /tmp/ucr_vars
ucr shell | grep -v ^hostname= >> /tmp/ucr_vars

# Check if computer account exists
echo "# Computer Account Check" > /tmp/computer_check
computer_exists=$(udm computers/linux list --filter cn=$HOSTNAME | grep -c DN:)
computer_exists_with_dollar=$(udm computers/linux list --filter cn=${HOSTNAME}\$ | grep -c DN:)
echo "computer_exists=$computer_exists" >> /tmp/computer_check
echo "computer_exists_with_dollar=$computer_exists_with_dollar" >> /tmp/computer_check

# Get computer DN if it exists
if [ "$computer_exists" -gt 0 ]; then
    computer_dn=$(udm computers/linux list --filter cn=$HOSTNAME | grep DN: | cut -d' ' -f2-)
    echo "computer_dn=\"$computer_dn\"" >> /tmp/computer_check
elif [ "$computer_exists_with_dollar" -gt 0 ]; then
    computer_dn=$(udm computers/linux list --filter cn=${HOSTNAME}\$ | grep DN: | cut -d' ' -f2-)
    echo "computer_dn=\"$computer_dn\"" >> /tmp/computer_check
fi

# Get LDAP base from UCR
ldap_base=$(ucr get ldap/base)

# Create or update computer account
echo "# Computer Account Operation" > /tmp/computer_operation
if [ "$computer_exists" -gt 0 ] || [ "$computer_exists_with_dollar" -gt 0 ]; then
    echo "action=modify" >> /tmp/computer_operation
    udm computers/linux modify \
        --dn "$computer_dn" \
        --set password="$PASSWORD" \
        --set operatingSystem="Rocky Linux" \
        --set operatingSystemVersion="$ROCKY_VERSION" >> /tmp/computer_operation 2>&1
else
    echo "action=create" >> /tmp/computer_operation
    udm computers/linux create \
        --position "cn=computers,${ldap_base}" \
        --set name="$HOSTNAME" \
        --set password="$PASSWORD" \
        --set operatingSystem="Rocky Linux" \
        --set operatingSystemVersion="$ROCKY_VERSION" >> /tmp/computer_operation 2>&1
fi

# Get domain groups
echo "# Domain Groups" > /tmp/domain_groups
# First try Domain* groups
domain_groups=$(udm groups/group list --filter cn=Domain* | grep DN: | cut -d' ' -f2-)
if [ -z "$domain_groups" ]; then
    # If no Domain* groups found, try groups with "domain" in their name (case insensitive)
    domain_groups=$(udm groups/group list | grep -i domain | grep DN: | cut -d' ' -f2-)
fi
if [ -z "$domain_groups" ]; then
    # If still no groups found, try to get all groups
    domain_groups=$(udm groups/group list --filter objectClass=univentionGroup | grep DN: | cut -d' ' -f2-)
fi
echo "$domain_groups" > /tmp/domain_groups_list

# Add computer to domain groups
echo "# Group Membership" > /tmp/group_membership
computer_cn="cn=${HOSTNAME},cn=computers,${ldap_base}"
if [ -n "$domain_groups" ]; then
    while read -r group_dn; do
        if [ -n "$group_dn" ]; then
            echo "Processing group: $group_dn" >> /tmp/group_membership
            udm groups/group modify \
                --dn "$group_dn" \
                --append hosts="$computer_cn" >> /tmp/group_membership 2>&1 || \
                echo "Warning: Failed to add computer to group: $group_dn" >> /tmp/group_membership
        fi
    done < /tmp/domain_groups_list
else
    echo "Warning: No groups found to add the computer to." >> /tmp/group_membership
fi

# Combine all results
cat /tmp/ucr_vars /tmp/computer_check /tmp/computer_operation /tmp/domain_groups /tmp/group_membership > /tmp/domain_join_results

# Clean up
rm -f /tmp/ucr_vars /tmp/computer_check /tmp/computer_operation /tmp/domain_groups /tmp/domain_groups_list /tmp/group_membership
EOF

# Copy the helper script to the UCS server
$SSH_CMD root@$REALMDC.$REALMAD "cat > /tmp/domain_join_helper.sh" < /tmp/ucs_join_helper/domain_join_helper.sh
$SSH_CMD root@$REALMDC.$REALMAD "chmod +x /tmp/domain_join_helper.sh"

# Execute the helper script on the UCS server
echo "Executing domain join operations on UCS server..."
$SSH_CMD root@$REALMDC.$REALMAD "/tmp/domain_join_helper.sh '$hostname_short' '$password' '$rocky_version'" > /tmp/ucs_join_helper/domain_join_results

# Extract UCR variables from the results
grep -v "^#" /tmp/ucs_join_helper/domain_join_results | sed -n '/^# UCR Variables/,/^# Computer Account Check/p' | grep -v "^#" > /etc/univention/ucr_master
echo "master_ip=$REALMDC.$REALMAD" >> /etc/univention/ucr_master
chmod 660 /etc/univention/ucr_master

# Source the UCR variables
. /etc/univention/ucr_master

# Save the password
printf '%s' "$password" > /etc/ldap.secret
chmod 0400 /etc/ldap.secret

# Get UCS CA certificate
echo "Retrieving UCS CA certificate..."
mkdir -p /etc/univention/ssl/ucsCA
$SSH_CMD root@$REALMDC.$REALMAD "cat /etc/univention/ssl/ucsCA/CAcert.pem" > /etc/univention/ssl/ucsCA/CAcert.pem

# Create ldap.conf
rm -f /etc/openldap/ldap.conf
mkdir -p /etc/openldap
cat > /etc/openldap/ldap.conf << EOF
TLS_CACERT /etc/univention/ssl/ucsCA/CAcert.pem
URI ldap://$ldap_master:7389
BASE $ldap_base
EOF

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

# Clean up SSH connection
echo "Cleaning up..."
$SSH_CMD -O exit root@$REALMDC.$REALMAD
kill $SSH_PID 2>/dev/null
rm -rf /tmp/ucs_join_helper
$SSH_CMD root@$REALMDC.$REALMAD "rm -f /tmp/domain_join_helper.sh /tmp/domain_join_results" || true

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
