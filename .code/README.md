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

## Enhanced Group Mapping

The implementation now includes enhanced group mapping functionality that ensures both user and machine groups are properly mapped from the UCS domain to the local system:

1. **Enhanced Group Mapping Configuration**:
   ```
   # Enhanced group mapping
   ldap_group_nesting_level = 5
   ldap_initgroups_use_matching_rule_in_chain = True
   ldap_user_principal = uid
   ldap_group_member_of_user_attr = dn
   
   # Machine account group membership
   ldap_use_tokengroups = False
   ```

2. **Group Search Filters**:
   ```
   ldap_group_search_base = $ldap_base
   ldap_group_search_filter = (|(objectClass=posixGroup)(objectClass=univentionGroup)(objectClass=sambaGroupMapping))
   ```

3. **Machine Account Group Membership**:
   - Adds the `objectFlag=posix` attribute to machine accounts
   - Automatically adds machine accounts to domain groups
   - Configures SSSD to properly handle machine group memberships

4. **Group Membership Synchronization**:
   - The `update-group-mapping.sh` script updates SSSD configuration with enhanced group mapping
   - Creates a synchronization script that runs periodically via cron
   - Ensures both user and machine groups are properly synchronized

### Testing Group Mapping

You can verify the group mapping is working correctly by running:
```shell
id username  # Check user group memberships
getent group groupname  # Check group members
```

## Future Improvements

Potential future improvements include:
- Support for more RHEL-based distributions (CentOS, Alma Linux, etc.)
- Support for more complex LDAP schemas
- Integration with Samba/AD authentication as an alternative to LDAP
