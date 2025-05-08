# Demo AutoFS

I need a lab where I can experiment with autofs.
This demo sets up 3 VMs on OpenShift Virtualization.

* LDAP Server
* NFS Server
* NFS Client

## LDAP Server

[LDAP server](ldap/base/kustomization.yaml) is RHEL9 with OpenLDAP. Since Red Hat [dropped](https://access.redhat.com/solutions/3816971) the openldap-servers package as of RHEL8 it comes from elsewhere.

The LDIFS are in a config map comprised of [these files](ldap/base/scripts/) which is mounted at `/opt`.
They are applied by the [cloud-init file](ldap/base/scripts/userData).

This appears to be adequately configured so far.

## NFS Server

[NFS Server](nfs/base/kustomization.yaml)

This is in progress.

## NFS Client

[Client Server](client/base/kustomization.yaml)
This is in progress.

## See Also

* https://github.com/dlbewley/openshift-automount-nfs-poc/tree/rev2025