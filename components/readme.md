# Components

This directory contains the following reusable Kustomize components:

* [Client](client/) - Workstation VM that mounts NFS shares via autofs
* [LDAP](ldap/) - LDAP server VM providing authentication services
* [Networking](networking/) - Network configuration and policies
* [NFS](nfs/) - NFS server VM providing shared storage

## Component Details

### Client
The client component deploys a virtual machine that acts as a workstation. It is configured to use autofs to automatically mount NFS shares and authenticates users against the LDAP server.

### LDAP
The LDAP component deploys a virtual machine running an LDAP server. This provides centralized authentication services for the environment, allowing users to authenticate across different services and systems.

### Networking
The networking component contains the necessary network configuration and policies to enable communication between all components. This includes network policies, routes, and other networking resources required for the solution.

### NFS
The NFS component deploys a virtual machine configured as an NFS server. It provides shared storage that can be mounted by client machines using autofs. The shares are accessible to authenticated users based on LDAP credentials.
