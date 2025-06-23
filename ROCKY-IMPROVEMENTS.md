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

- Support for RFC2307bis schema
- Proper attribute mappings for users and groups
- Group mapping support via conf.d directory
- Domain Admins to wheel group mapping for administrative access

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
