# Rocky Linux UCS Domain Join with LDAP Authentication

This directory contains the code and documentation for adding Rocky Linux support to the Univention Domain Join tool, specifically using LDAP authentication instead of Samba/AD.

## Overview

The implementation adds support for Rocky Linux 8 and 9 to join a Univention Corporate Server (UCS) domain using LDAP authentication. This is different from the default behavior for Ubuntu/Linux Mint, which uses both Kerberos and LDAP.

## Files

1. **setup-rocky.sh**: A standalone script for joining Rocky Linux systems to a UCS domain using LDAP authentication.
2. **rocky.py**: The Rocky Linux distribution module for integration with the main Univention Domain Join codebase.

## Key Features

- Uses LDAP for both identity provider and authentication provider
- Configures proper user attribute mappings for complete user information display
- Sets up fallback home directory paths for users without defined home directories
- Handles SELinux configuration to allow LDAP authentication
- Uses Rocky Linux-specific tools (dnf, authselect) and paths (/etc/openldap)

## Implementation Details

### User Mapping Improvements

The initial implementation only showed UIDs on Rocky Linux systems. The updated version includes:

1. **Enhanced User Attribute Mappings**:
   ```
   ldap_user_object_class = posixAccount
   ldap_user_name = uid
   ldap_user_uid_number = uidNumber
   ldap_user_gid_number = gidNumber
   ldap_user_home_directory = homeDirectory
   ldap_user_shell = loginShell
   ldap_user_gecos = displayName
   ldap_user_member_of = memberOf
   ldap_user_uuid = entryUUID
   ```

2. **Group Mappings**:
   ```
   ldap_group_object_class = posixGroup
   ldap_group_name = cn
   ldap_group_gid_number = gidNumber
   ldap_group_member = uniqueMember
   ldap_group_uuid = entryUUID
   ```

3. **ID Mapping Configuration**:
   ```
   ldap_id_mapping = False
   ldap_idmap_autorid_compat = True
   ```

4. **Home Directory Configuration**:
   ```
   fallback_homedir = /home/%u
   default_shell = /bin/bash
   ```

### Rocky Linux-Specific Adaptations

1. **Package Management**: Uses `dnf` instead of `apt` for package installation
2. **LDAP Configuration**: Uses `/etc/openldap/ldap.conf` instead of `/etc/ldap/ldap.conf`
3. **PAM Configuration**: Uses `authselect` instead of `pam-auth-update`
4. **SELinux Configuration**: Sets the `authlogin_nsswitch_use_ldap` boolean to allow LDAP authentication

## Usage

### New Installation

To join a Rocky Linux system to a UCS domain:

```bash
sudo ./setup-rocky.sh
```

Follow the prompts to provide:
- UCS domain name
- Domain controller's hostname
- Domain admin username

### Updating Existing Installation

For systems already joined to the domain but only showing UIDs, you can update the SSSD configuration:

1. Edit `/etc/sssd/sssd.conf`
2. Replace the `[domain/...]` section with the enhanced configuration
3. Restart SSSD: `systemctl restart sssd`

## Testing

The implementation has been tested on:
- Rocky Linux 8
- Rocky Linux 9

## Future Improvements

Potential future improvements include:
- Support for more RHEL-based distributions (CentOS, Alma Linux, etc.)
- Enhanced group membership handling
- Support for more complex LDAP schemas
