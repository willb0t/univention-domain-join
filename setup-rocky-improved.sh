#!/bin/bash
# Improved script for joining Rocky Linux to UCS domain using LDAP authentication
# SPDX-FileCopyrightText: 2025 Univention GmbH
# SPDX-License-Identifier: AGPL-3.0-only

# Function for logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function for error handling
handle_error() {
    log "ERROR: $1"
    log "Domain join failed. Please check the error and try again."
    log "You can run reset_rocky.sh to clean up before retrying."
    exit 1
}

# Check if running on Rocky Linux
if [ -f /etc/rocky-release ]; then
    ROCKY_VERSION=$(cat /etc/rocky-release | grep -oP '[\d\.]+' | head -1)
    MAJOR_VERSION=${ROCKY_VERSION%%.*}
    log "Rocky Linux $ROCKY_VERSION detected"
else
    handle_error "This script is intended for Rocky Linux. Exiting."
fi

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    handle_error "This script must be run as root. Please use sudo or switch to the root user."
fi

# Create backup directory
BACKUP_DIR="/var/univention-backup/$(date '+%Y%m%d%H%M%S')_domain-join"
mkdir -p $BACKUP_DIR
log "Created backup directory at $BACKUP_DIR"

# Backup existing configuration files
backup_configs() {
    log "Backing up existing configuration files..."
    
    # Backup LDAP config
    if [ -f /etc/openldap/ldap.conf ]; then
        mkdir -p $BACKUP_DIR/etc/openldap
        cp /etc/openldap/ldap.conf $BACKUP_DIR/etc/openldap/
    fi
    
    # Backup SSSD config
    if [ -d /etc/sssd ]; then
        mkdir -p $BACKUP_DIR/etc/sssd
        cp -r /etc/sssd/* $BACKUP_DIR/etc/sssd/
    fi
    
    # Backup PAM config
    mkdir -p $BACKUP_DIR/etc/pam.d
    cp -r /etc/pam.d/* $BACKUP_DIR/etc/pam.d/
    
    # Backup authselect profile
    if [ -d /etc/authselect ]; then
        mkdir -p $BACKUP_DIR/etc/authselect
        cp -r /etc/authselect/* $BACKUP_DIR/etc/authselect/
    fi
    
    log "Configuration backup complete"
}

# Install required packages
install_packages() {
    log "Installing necessary packages..."
    
    # Update package cache
    dnf clean metadata || log "Warning: Failed to clean metadata, continuing anyway"
    dnf makecache || log "Warning: Failed to make cache, continuing anyway"
    
    # Define packages to install
    PACKAGES=(
        sssd
        sssd-ldap
        sssd-tools
        openldap-clients
        oddjob
        oddjob-mkhomedir
        authselect
        authselect-compat
        realmd
        adcli
    )
    
    # Try to install all packages at once
    if ! dnf -y install "${PACKAGES[@]}"; then
        log "Bulk package installation failed, trying individual packages..."
        
        # Try installing packages one by one
        FAILED_PKGS=()
        for pkg in "${PACKAGES[@]}"; do
            if ! dnf -y install $pkg; then
                FAILED_PKGS+=($pkg)
                log "Warning: Failed to install $pkg"
            fi
        done
        
        # Check if any critical packages failed
        CRITICAL_PKGS=(sssd sssd-ldap openldap-clients oddjob-mkhomedir authselect)
        for pkg in "${CRITICAL_PKGS[@]}"; do
            if [[ " ${FAILED_PKGS[@]} " =~ " $pkg " ]]; then
                handle_error "Critical package $pkg failed to install. Cannot continue."
            fi
        done
        
        if [ ${#FAILED_PKGS[@]} -gt 0 ]; then
            log "Warning: Some non-critical packages failed to install: ${FAILED_PKGS[*]}"
        fi
    fi
    
    log "Package installation completed"
}

# Get domain information
get_domain_info() {
    log "Gathering domain information..."
    
    # Get domain information from user
    read -p "What is the UCS domain? (dom.example.com): " REALMAD
    read -p "What is the domain controller's short hostname? ('dc' part of dc.dom.example.com): " REALMDC
    read -p "What is the domain admin username? " REALMADMIN
    
    # Validate inputs
    if [ -z "$REALMAD" ] || [ -z "$REALMDC" ] || [ -z "$REALMADMIN" ]; then
        handle_error "Domain information cannot be empty"
    fi
    
    # Set hostname variables
    SHORTHOST=${HOSTNAME%%.*}
    
    log "Domain information gathered successfully"
}

# Get UCS configuration
get_ucs_config() {
    log "Connecting to $REALMDC.$REALMAD UCS server and pulling UCS config..."
    
    mkdir -p /etc/univention
    
    # Try to get UCS configuration
    if ! ssh -n root@$REALMDC.$REALMAD 'ucr shell | grep -v ^hostname=' >/etc/univention/ucr_master; then
        handle_error "Failed to connect to UCS server or retrieve UCR configuration"
    fi
    
    echo "master_ip=$REALMDC.$REALMAD" >>/etc/univention/ucr_master
    chmod 660 /etc/univention/ucr_master
    
    # Source the UCS configuration
    . /etc/univention/ucr_master
    
    # Validate essential variables
    if [ -z "$ldap_base" ] || [ -z "$kerberos_realm" ] || [ -z "$ldap_master" ]; then
        handle_error "Essential UCS configuration variables are missing"
    fi
    
    log "UCS configuration retrieved successfully"
}

# Create computer account
create_computer_account() {
    log "Creating computer account on $REALMDC.$REALMAD UCS server..."
    
    # Generate random password
    password="$(tr -dc A-Za-z0-9_\!\@\#\$\%\^\&\*\(\)-+ </dev/urandom | head -c20)"
    
    # Check if computer account already exists
    if ssh -n root@$REALMDC.$REALMAD udm computers/linux list --filter name=$(hostname) | grep -q "DN: cn=$(hostname),cn=computers,${ldap_base}"; then
        log "Computer account $(hostname) already exists. Attempting to remove it first..."
        
        # Try to remove existing computer account
        if ssh -n root@$REALMDC.$REALMAD udm computers/linux remove --dn="cn=$(hostname),cn=computers,${ldap_base}"; then
            log "Existing computer account removed successfully"
        else
            handle_error "Failed to remove existing computer account. Please run reset_rocky.sh or manually remove the account first."
        fi
    fi
    
    # Create computer account
    if ! ssh -n root@$REALMDC.$REALMAD udm computers/linux create \
        --position "cn=computers,${ldap_base}" \
        --set name=$(hostname) --set password="${password}" \
        --set operatingSystem="Rocky Linux" \
        --set operatingSystemVersion="$ROCKY_VERSION"; then
        handle_error "Failed to create computer account on UCS server. If the account already exists, please run reset_rocky.sh first."
    fi
    
    # Save password
    printf '%s' "$password" >/etc/machine.secret
    chmod 0400 /etc/machine.secret
    
    log "Computer account created successfully"
}

# Get UCS CA certificate
get_ca_certificate() {
    log "Retrieving UCS CA certificate..."
    
    mkdir -p /etc/univention/ssl/ucsCA
    
    if ! scp root@$REALMDC.$REALMAD:/etc/univention/ssl/ucsCA/CAcert.pem /etc/univention/ssl/ucsCA/; then
        handle_error "Failed to retrieve UCS CA certificate"
    fi
    
    log "UCS CA certificate retrieved successfully"
}

# Configure LDAP
configure_ldap() {
    log "Configuring LDAP..."
    
    # Create LDAP configuration
    mkdir -p /etc/openldap
    cat > /etc/openldap/ldap.conf << EOF
TLS_CACERT /etc/univention/ssl/ucsCA/CAcert.pem
URI ldap://$ldap_master:7389
BASE $ldap_base
EOF
    
    # Get machine DN
    machine_dn="cn=$(hostname),cn=computers,$ldap_base"
    
    log "LDAP configuration completed"
}

# Configure SSSD
configure_sssd() {
    log "Configuring SSSD for LDAP authentication..."
    
    # Get machine password
    ldap_password=$(cat /etc/machine.secret)
    
    # Create SSSD configuration directory
    mkdir -p /etc/sssd/conf.d
    
    # Create main SSSD configuration
    cat > /etc/sssd/sssd.conf << EOF
[sssd]
config_file_version = 2
reconnection_retries = 3
sbus_timeout = 30
services = nss, pam, sudo
domains = $kerberos_realm
conf_db = /etc/sssd/conf.d

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
ldap_default_authtok = $ldap_password
ldap_schema = rfc2307bis
ldap_id_mapping = False
ldap_user_member_of = memberOf
ldap_user_gecos = displayName
ldap_user_uuid = entryUUID
ldap_group_uuid = entryUUID
ldap_group_member = uniqueMember
cache_credentials = true
enumerate = true
EOF
    
    # Set proper permissions
    chmod 600 /etc/sssd/sssd.conf
    
    # Create group mapping configuration
    cat > /etc/sssd/conf.d/group_mapping.conf << EOF
[domain/$kerberos_realm]
# Map Domain Admins to wheel group
ldap_group_external_member = cn=Domain Admins,cn=groups,$ldap_base:wheel
EOF
    
    log "SSSD configuration completed"
}

# Configure PAM
configure_pam() {
    log "Configuring PAM for home directory creation..."
    
    # Use authselect to configure PAM with mkhomedir
    if ! authselect select sssd with-mkhomedir --force; then
        handle_error "Failed to configure PAM with authselect"
    fi
    
    log "PAM configuration completed"
}

# Configure SELinux
configure_selinux() {
    log "Configuring SELinux..."
    
    # Check if SELinux is enabled
    if command -v getenforce &> /dev/null; then
        selinux_status=$(getenforce)
        if [[ "$selinux_status" != "Disabled" ]]; then
            log "SELinux is enabled ($selinux_status). Setting required booleans..."
            
            # Set SELinux booleans
            setsebool -P authlogin_nsswitch_use_ldap=on || log "Warning: Failed to set authlogin_nsswitch_use_ldap boolean"
            setsebool -P authlogin_yubikey=on || log "Warning: Failed to set authlogin_yubikey boolean"
            setsebool -P httpd_can_connect_ldap=on || log "Warning: Failed to set httpd_can_connect_ldap boolean"
        else
            log "SELinux is disabled. Skipping SELinux configuration."
        fi
    else
        log "SELinux tools not found. Skipping SELinux configuration."
    fi
}

# Restart and enable services
configure_services() {
    log "Restarting and enabling services..."
    
    # Restart SSSD
    systemctl restart sssd || handle_error "Failed to restart SSSD service"
    
    # Enable SSSD to start at boot
    systemctl enable sssd || log "Warning: Failed to enable SSSD service at boot"
    
    # Enable oddjob-mkhomedir service
    systemctl enable --now oddjobd || log "Warning: Failed to enable oddjobd service"
    
    log "Services configured successfully"
}

# Verify domain join
verify_domain_join() {
    log "Verifying domain join..."
    
    # Test LDAP connection
    if ldapsearch -x -H "ldap://$ldap_master:7389" -b "$ldap_base" -s base &> /dev/null; then
        log "LDAP connection test: SUCCESS"
    else
        log "LDAP connection test: FAILED"
    fi
    
    # Test SSSD configuration
    if sssctl domain-status "$kerberos_realm" &> /dev/null; then
        log "SSSD domain status: SUCCESS"
    else
        log "SSSD domain status: FAILED"
    fi
    
    # Try to get domain users
    if getent passwd "Administrator@$kerberos_realm" &> /dev/null; then
        log "Domain user lookup: SUCCESS"
    else
        log "Domain user lookup: FAILED (This might be normal if Administrator doesn't exist)"
    fi
    
    log "Verification completed. Some tests may fail immediately after setup and succeed after a reboot."
}

# Main execution
main() {
    log "Starting Rocky Linux domain join process..."
    
    # Execute all steps
    backup_configs
    install_packages
    get_domain_info
    get_ucs_config
    create_computer_account
    get_ca_certificate
    configure_ldap
    configure_sssd
    configure_pam
    configure_selinux
    configure_services
    verify_domain_join
    
    log "UCS LDAP Domain Join Complete!"
    log "You can now authenticate with domain users."
    log "Note: You may need to reboot for all changes to take effect."
    
    # Prompt for reboot
    read -r -p "REBOOT NOW? [y/N] " rebootnow
    if [[ "$rebootnow" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
        log "Rebooting!"
        reboot
    else
        log "Reboot not selected. Please reboot manually when convenient."
    fi
}

# Run the main function
main
