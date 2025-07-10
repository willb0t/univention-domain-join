# Rocky Linux - Univention Domain Join Improvements

This document outlines the improvements made to the Rocky Linux domain join process for Univention Corporate Server (UCS) environments.

## New Scripts

Two new scripts have been created to improve the Rocky Linux domain join process:

1. `setup-rocky-improved.sh` - An improved domain join script with better error handling, more comprehensive configuration, and additional features.
2. `reset_rocky.sh` - A cleanup script to remove all Univention domain join settings, allowing for a clean restart of the domain join process.

## Key Improvements

### 1. Enhanced Error Handling

The improved setup script includes comprehensive error handling throughout the process:

- Each step is wrapped with proper error checking
- Detailed error messages with suggestions for resolution
- Graceful failure that preserves the system state
- References to the reset script for cleanup after failures

### 2. Better Package Management

Package installation has been improved:

- Package cache is updated before installation
- Bulk installation with fallback to individual package installation
- Distinction between critical and non-critical packages
- Detailed logging of package installation status

### 3. Comprehensive Configuration Backup

A more thorough backup system:

- All configuration files are backed up before modification
- Timestamped backup directories
- Organized directory structure matching the original system

### 4. Enhanced SSSD Configuration

SSSD configuration has been improved:

- Support for RFC2307bis schema with proper LDAP group attributes
- Comprehensive attribute mappings for users and groups including:
  - `ldap_group_member = uniqueMember` (UCS uses uniqueMember)
  - `ldap_group_object_class = univentionGroup` (UCS group object class)
  - `ldap_group_name = cn` (group name attribute)
  - `ldap_group_gid_number = gidNumber` (group ID attribute)
  - `ldap_group_nesting_level = 2` (support for nested groups)
  - `ldap_id_mapping = False` (use POSIX IDs from LDAP)
- Group mapping support via conf.d directory
- Domain Admins to wheel group mapping for administrative access
- Enhanced group resolution and membership handling

### 5. Improved SELinux Configuration

SELinux handling has been enhanced:

- Detection of SELinux status
- Multiple boolean settings for comprehensive access
- Graceful handling of SELinux-related errors

### 6. Verification and Diagnostics

New verification capabilities:

- LDAP connection testing
- SSSD domain status verification
- User lookup testing
- Detailed logging of verification results

### 7. Modular Script Design

The improved script uses a modular design:

- Functions for each major step
- Consistent logging format
- Clear separation of concerns
- Main execution function for better readability

## Usage Instructions

### Setting Up a Rocky Linux Client

To join a Rocky Linux client to a Univention domain:

1. Make the script executable:
   ```
   chmod +x setup-rocky-improved.sh
   ```

2. Run the script as root:
   ```
   sudo ./setup-rocky-improved.sh
   ```

3. Follow the prompts to provide:
   - UCS domain name (e.g., dom.example.com)
   - Domain controller's short hostname (e.g., dc)
   - Domain admin username

4. The script will:
   - Install necessary packages
   - Configure LDAP authentication
   - Set up SSSD for user authentication
   - Configure PAM for home directory creation
   - Handle SELinux settings
   - Verify the domain join

5. Reboot when prompted to complete the setup.

### Resetting a Rocky Linux Client

If you need to remove the domain join configuration:

1. Make the script executable:
   ```
   chmod +x reset_rocky.sh
   ```

2. Run the script as root:
   ```
   sudo ./reset_rocky.sh
   ```

3. Confirm that you want to remove all domain join settings.

4. Optionally choose to remove installed packages.

5. Reboot when prompted to complete the reset.

## Troubleshooting

If you encounter issues during the domain join process:

1. Check the error messages displayed by the script for specific guidance.

2. Run the reset script to clean up any partial configuration:
   ```
   sudo ./reset_rocky.sh
   ```

3. Address any issues mentioned in the error messages.

4. Try the domain join again with the improved setup script.

Common issues and solutions:

- **SSH Connection Failures**: Ensure the UCS server is reachable and that you have the correct hostname.
- **Package Installation Failures**: Check network connectivity and repository configuration.
- **LDAP Connection Issues**: Verify firewall settings and that the UCS server's LDAP service is running.
- **Authentication Failures**: Ensure the domain admin credentials are correct.

## Technical Details

### OpenLDAP Group Mapping Fixes

The Rocky Linux implementation now includes comprehensive OpenLDAP group mapping fixes:

#### Group Attribute Configuration
- **ldap_group_member**: Set to `uniqueMember` to match UCS LDAP schema
- **ldap_group_object_class**: Set to `univentionGroup` for proper UCS group recognition
- **ldap_group_name**: Set to `cn` for group name resolution
- **ldap_group_gid_number**: Set to `gidNumber` for proper GID mapping
- **ldap_group_nesting_level**: Set to `2` to support nested group memberships
- **ldap_id_mapping**: Set to `False` to use POSIX IDs directly from LDAP

#### Administrative Group Mapping
- Domain Admins group is automatically mapped to the local `wheel` group
- Members of Domain Admins gain sudo privileges through wheel group membership
- Sudoers configuration ensures wheel group has administrative access
- Group mapping is configured via `/etc/sssd/conf.d/group_mapping.conf`

#### Verification and Testing
- LDAP connection testing during domain join
- SSSD domain status verification
- Group lookup testing for Domain Admins
- Configuration file existence verification
- Comprehensive logging of all verification steps

### LDAP Configuration

The improved script configures LDAP to use the correct path for Rocky Linux (`/etc/openldap/ldap.conf`) and sets up proper TLS certificate validation.

### SSSD Configuration

SSSD is configured with:

- LDAP as both the identity and authentication provider
- Proper schema settings for Univention's LDAP structure
- Group mapping for administrative access
- Credential caching for offline authentication

### SELinux Configuration

SELinux booleans are set to allow:

- LDAP authentication via NSS
- Yubikey authentication if used
- Web services to connect to LDAP if needed

### PAM Configuration

PAM is configured using authselect with the SSSD and mkhomedir modules to:

- Enable SSSD authentication
- Create home directories for domain users on first login
