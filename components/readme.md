# Components

This directory contains the following reusable Kustomize components:

* [Client](client/) - Workstation VM that mounts NFS shares via autofs
* [LDAP](ldap/) - LDAP server VM providing authentication services
* [Networking](networking/) - Network configuration and policies
* [NFS](nfs/) - NFS server VM providing shared storage
* [localnet-1924](localnet-1924/) - VLAN 1924 network configuration with static IP allocation provided by OpenShift OVN
* [localnet-1924-DHCP](localnet-1924-dhcp/) - VLAN 1924 network configuration with DHCP provided by the datacenter

## Component Details

### Client
The client component deploys a virtual machine that acts as a workstation. It is configured to use autofs to automatically mount NFS shares and authenticates users against the LDAP server.

### LDAP
The LDAP component deploys a virtual machine running an LDAP server. This provides centralized authentication services for the environment, allowing users to authenticate across different services and systems.

### Networking
The networking component contains the necessary network configuration and policies to enable communication between all components. This includes network policies, routes, and other networking resources required for the solution.

### localnet-1924
The localnet-1924 component defines a ClusterUserDefinedNetwork that configures VLAN 1924 with static IP allocation managed by OpenShift OVN-Kubernetes. It provides IP address management for namespaces labeled with `localnet: "1924"`, excluding specific subnet ranges (192.168.4.0/25, 192.168.4.128/26, and 192.168.4.240/28) from automatic allocation.

### localnet-1924-DHCP
The localnet-1924-DHCP component also defines a ClusterUserDefinedNetwork for VLAN 1924, but configures it to use external DHCP services provided by the datacenter infrastructure instead of OpenShift's built-in IP allocation. This allows pods in labeled namespaces to obtain IP addresses from the existing datacenter DHCP server.
It will be available to namespaces labeled with `localnet: "1924"`

### NFS
The NFS component deploys a virtual machine configured as an NFS server. It provides shared storage that can be mounted by client machines using autofs. The shares are accessible to authenticated users based on LDAP credentials.
