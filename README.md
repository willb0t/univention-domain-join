<!--
SPDX-FileCopyrightText: 2017-2023 Univention GmbH
SPDX-License-Identifier: AGPL-3.0-only
-->
# Univention Domain Join

This is an assistant for joining [Ubuntu](https://ubuntu.com/about/release-cycle), [Linux Mint](https://www.linuxmint.com/download_all.php), and [Rocky Linux](https://rockylinux.org/) computers into Univention Corporate
Server (UCS) domains. It will perform the following steps for you:

- Create an LDAP object for your Ubuntu computer on UCS
- Configure DNS
- Configure Kerberos
- Configure the login manager, if necessary
- Configure PAM
- Configure SSSD

Univention Domain Join supports the following Linux distributions:

- `rocky9`
  - Rocky Linux 9
- `rocky8`
  - Rocky Linux 8
- `ubuntu24.04`
  - Ubuntu 24.04 LTS ("Noble Numbat")
- `ubuntu22.04`
  - Ubuntu 22.04 LTS („Jammy Jellyfish")
  - Linux Mint 21 („Vanessa")
- `ubuntu20.04`
  - Ubuntu 20.04 LTS („Focal Fossa")
  - Linux Mint 20 („Ulyana")
- `ubuntu18.04`
  - Ubuntu 18.04 LTS („Bionic Beaver")
  - Linux Mint 19.2 („Tara")
- `ubuntu17.10`
  - Ubuntu 17.10 („Artful Aardvark")
- `ubuntu16.04`
  - Ubuntu 16.04 LTS („Xenial Xerus")
- `ubuntu14.04`
  - Ubuntu 14.04 LTS („Trusty Tahr")

The actual source code for the different Ubuntu releases can be found in
the corresponding git branches.

Univention Domain Join supports the Gnome and Unity desktop environments. The
configuration of the login manager of other desktop environments may not work,
but can be skipped using the `--skip-login-manager` parameter of the
`univention-domain-join-cli` tool.

# Download and Installation

You can install Univention Domain Join assistant on Ubuntu via the [PPA of
Univention](https://launchpad.net/~univention-dev/+archive/ubuntu/ppa) using
these commands:

```shell
sudo add-apt-repository ppa:univention-dev/ppa
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install univention-domain-join
```

Run the assistant using the start menu.

There is also a command line tool `univention-domain-join-cli`, which can be installed separately
with the package `univention-domain-join-cli`.
Run `sudo univention-domain-join-cli --help` for more details.

## Rocky Linux Installation

For Rocky Linux, you can use the provided `setup-rocky.sh` script to join the UCS domain using LDAP authentication:

```shell
sudo ./setup-rocky.sh
```

This script will:
1. Install the necessary packages
2. Configure LDAP authentication
3. Set up SSSD for user authentication with enhanced group mapping
4. Add the machine account to domain groups
5. Configure PAM for home directory creation
6. Handle SELinux settings

### Enhanced Group Mapping for Rocky Linux

The Rocky Linux implementation includes enhanced group mapping functionality that ensures both user and machine groups are properly mapped from the UCS domain to the local system. This includes:

- Support for nested groups with configurable nesting level
- Proper mapping of all group attributes
- Machine account group membership
- Support for RFC2307bis schema

If you've already joined a Rocky Linux system to the domain and want to enhance the group mapping, you can use the provided `update-group-mapping.sh` script:

```shell
sudo ./update-group-mapping.sh
```

This script will:
1. Update the SSSD configuration with enhanced group mapping options
2. Create a group membership synchronization script
3. Set up a cron job to periodically synchronize group memberships
4. Restart SSSD to apply the changes

You can verify the group mapping is working correctly by running:
```shell
id username  # Check user group memberships
getent group groupname  # Check group members
```

# Doc

Documentation on how to build and release this package to launchpad can be found [here](doc/dev.md)

# License

Univention Domain Join is built on top of many existing open source projects
which use their own licenses. The source code of all parts written by
Univention is licensed under the AGPLv3 . Please see the
[license file](./LICENSE) for more information.
