# Components

This directory contains the following reusable Kustomize components:

* [argocd-net-management](argocd-net-management/) - RBAC permissions for ArgoCD to manage networking resources
* [argocd-vm-management](argocd-vm-management/) - RBAC permissions for ArgoCD to manage virtual machines
* [automount-role](automount-role/) - RBAC permissions for automount operations including privileged SCC access
* [localnet-1924](localnet-1924/) - VLAN 1924 network configuration with static IP allocation provided by OpenShift OVN
* [localnet-1924-dhcp](localnet-1924-dhcp/) - VLAN 1924 network configuration with DHCP provided by the datacenter
* [physnet-mapping](physnet-mapping/) - Physical network bridge mapping configuration for OVN-Kubernetes
* [vms](vms/) - Virtual machine management and configuration components

## Component Details

### argocd-net-management
The argocd-net-management component provides the necessary RBAC permissions for ArgoCD to manage networking resources. It includes ClusterRole and ClusterRoleBinding that grant access to OVN-Kubernetes and NMState resources, as well as namespace-scoped Role and RoleBinding for user-defined networks.

### argocd-vm-management
The argocd-vm-management component provides RBAC permissions for ArgoCD to manage virtual machines and network policies. It includes Role and RoleBinding that grant access to KubeVirt virtual machines and multi-network policies.

### automount-role
The automount-role component provides RBAC permissions for automount operations, including access to privileged SecurityContextConstraints. This allows the automount service account to use privileged operations required for mounting network filesystems.

### localnet-1924
The localnet-1924 component defines a ClusterUserDefinedNetwork that configures VLAN 1924 with static IP allocation managed by OpenShift OVN-Kubernetes. It provides IP address management for namespaces labeled with `localnet: "1924"`, excluding specific subnet ranges (192.168.4.0/25, 192.168.4.128/26, and 192.168.4.240/28) from automatic allocation.

### localnet-1924-dhcp
The localnet-1924-dhcp component also defines a ClusterUserDefinedNetwork for VLAN 1924, but configures it to use external DHCP services provided by the datacenter infrastructure instead of OpenShift's built-in IP allocation. This allows pods in labeled namespaces to obtain IP addresses from the existing datacenter DHCP server. It will be available to namespaces labeled with `localnet: "1924"`.

### physnet-mapping
The physnet-mapping component contains NodeNetworkConfigurationPolicy resources that define the physical network bridge mappings for OVN-Kubernetes. It configures the `br-vmdata` bridge mapping to the `physnet-br-vmdata` physical network, enabling OVN to properly route traffic between virtual and physical networks.

### vms
The vms component contains virtual machine management and configuration resources. This includes templates, configurations, and other resources needed for deploying and managing virtual machines in the environment.
