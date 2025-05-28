# Demo AutoFS

## VM Infrastructure

These 3 VM deployments provide lab infrastructure for testing autofs with LDAP automount maps.

This demo sets up 3 VMs on OpenShift Virtualization.

* LDAP Server
* NFS Server
* NFS Client

> [!IMPORTANT]
> Update the organization ID and activation key in the `*/base/scripts/userData` files to valid values before deploying.

All of these VMs are attached only to the same VLAN as the nodes via a localnet NetworkAttachmentDefinition, and not to the primary pod (cluster) network.

## LDAP Server VM

[LDAP server](ldap/base/kustomization.yaml) is RHEL9 with OpenLDAP. Since Red Hat [dropped](https://access.redhat.com/solutions/3816971) the openldap-servers package as of RHEL8 it comes from elsewhere.

Setting up LDAP from scratch for autofs requires several LDIF files and properly ordred application.
The LDIFS are in a config map comprised of [these files](ldap/base/scripts/) which is mounted at `/opt`.
They are applied by the [cloud-init file](ldap/base/scripts/userData).

## NFS Server VM

[NFS Server](nfs/base/kustomization.yaml)

The exports are in a config map comprised of [the *.exports files](nfs/base/scripts/) which is mounted at `/opt/exports.d` and copied to `/etc/exports.d/` so as not to conflict with install of nfs-utils.

Users are created in `/exports/home` via [the cloud-init](nfs/base/scripts/userData) with the same UID/GID as was [defined in LDAP](ldap/base/scripts/users.ldif).

## NFS Client VM

[NFS Client](client/base/kustomization.yaml) configures sssd and autofs using configmaps [from here](client/base/scripts/).

User `cloud-user` has been relocated to `/local/home/cloud-user`. Users from ldap will automount at `/home/<user>`.

## NFS Client Node

Automounting filesystems on OpenShift nodes.
See WIP at [automount/](automount/)

# Run Autofs in a Pod

See [automount/](automount/). This was not entirely successful, so attention moved to running autofs directly in the Node OS.

# Run Autofs in the Node OS

See [layering/](layering/)

## Access NFS mounted host paths in pod

See [hostpath-volume/](hostpath-volume/)

# See Also

* https://github.com/dlbewley/openshift-automount-nfs-poc/tree/rev2025