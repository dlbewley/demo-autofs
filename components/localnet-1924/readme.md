# Localnet 1924 Network Component

This component defines a VLAN 1924 localnet network using OpenShift's OVN-Kubernetes ClusterUserDefinedNetwork (CUDN) resource with static IP allocation managed by OpenShift OVN-Kubernetes.

## Overview

The `localnet-1924` component creates a VLAN 1924 network that bridges virtual and physical networks, providing direct connectivity to the physical infrastructure. This network uses static IP allocation managed by OpenShift OVN-Kubernetes IPAM.

## Network Configuration

### Localnet Topology
- **Topology**: Localnet (bridges virtual and physical networks)
- **Role**: Secondary (additional network alongside the default cluster network)
- **VLAN ID**: 1924 (Access mode)
- **Physical Network**: `physnet-br-vmdata` (bridge mapping)
- **Subnet**: `192.168.4.0/24` (254 total IP addresses)
- **IPAM**: Static allocation managed by OpenShift OVN-Kubernetes

### Namespace Access
Namespaces can access this network by adding the label:
```yaml
metadata:
  labels:
    localnet: "1924"
```

## IP Address Management

### Available IP Ranges
- **Total Addresses**: 254 (192.168.4.1 - 192.168.4.254)
- **Available for Allocation**: 190 addresses
- **Reserved Ranges**:
  - `192.168.4.0/25` (192.168.4.0 - 192.168.4.127) - 128 addresses
  - `192.168.4.128/26` (192.168.4.128 - 192.168.4.191) - 64 addresses
  - `192.168.4.240/28` (192.168.4.240 - 192.168.4.255) - 16 addresses

### Allocatable Range
- **Available IPs**: 192.168.4.192 - 192.168.4.239 (48 addresses)
- **Lifecycle**: Static (IPs are assigned and retained by OVN-Kubernetes)

## Use Cases

This VLAN 1924 localnet network is ideal for:

- **Virtual Machines**: VMs that need direct physical network access
- **Infrastructure Services**: Services requiring physical network connectivity
- **Legacy Integration**: Applications needing traditional network access
- **Network Segmentation**: Isolated network segment for specific workloads
- **Physical Network Access**: Direct connectivity to physical infrastructure

## Prerequisites

- OpenShift cluster with OVN-Kubernetes CNI
- Physical network bridge `br-vmdata` configured on worker nodes
- Physical network mapping `physnet-br-vmdata` configured
- Cluster-admin privileges (CUDN creation requires cluster-admin)
- Proper RBAC permissions for ArgoCD to manage CUDN resources

## Dependencies

This component requires the [physnet-mapping](../physnet-mapping/) component to be deployed first, which configures the physical network bridge mapping.

## Usage

### Deploy as Component
```bash
# Include in kustomization.yaml
components:
  - ../../components/localnet-1924
```

### Manual Deployment
```bash
oc apply -f components/localnet-1924/clusteruserdefinednetwork.yaml
```

### Verify Deployment
```bash
# Check CUDN status
oc get cudn localnet-1924

# Check network attachment definitions in namespaces
oc get network-attachment-definitions -A

# Verify physical network mapping
oc get nncp ovs-bridge-mapping-physnet-br-vmdata
```

## Network Attachment

Pods can attach to this network by adding the following annotation:

```yaml
apiVersion: v1
kind: Pod
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: localnet-1924
spec:
  # pod spec
```

## Physical Network Requirements

### Bridge Configuration
The physical network requires:
- Bridge name: `br-vmdata`
- Physical network name: `physnet-br-vmdata`
- VLAN 1924 access configuration

### Worker Node Setup
Each worker node must have:
- OVS bridge `br-vmdata` configured
- VLAN 1924 trunk/access configuration
- Proper physical network connectivity

## Troubleshooting

### Common Issues

1. **CUDN Creation Fails**
   - Ensure cluster-admin privileges
   - Verify OVN-Kubernetes is properly configured
   - Check for conflicting network configurations
   - Verify physical network mapping exists

2. **Pod Network Attachment Fails**
   - Verify namespace has `localnet: "1924"` label
   - Check NetworkAttachmentDefinition exists in namespace
   - Ensure physical bridge `br-vmdata` is configured
   - Verify VLAN 1924 is properly configured

3. **IP Allocation Issues**
   - Check available IP range (192.168.4.192 - 192.168.4.239)
   - Verify no IP conflicts with existing allocations
   - Review CUDN status for allocation errors
   - Check OVN logical switch configuration

4. **Physical Network Connectivity Issues**
   - Verify bridge `br-vmdata` exists on worker nodes
   - Check VLAN 1924 configuration on physical switches
   - Verify physical network mapping configuration
   - Test connectivity from worker nodes

### Debug Commands

```bash
# Check CUDN detailed status
oc describe cudn localnet-1924

# Check network attachment definitions
oc get nad -A

# Check pod network interfaces
oc exec <pod-name> -- ip addr show

# Check OVN logical switches
oc get nodes -o jsonpath='{.items[*].metadata.annotations.k8s\.ovn\.org/node-subnets}'

# Check physical network mapping
oc describe nncp ovs-bridge-mapping-physnet-br-vmdata

# Check bridge configuration on worker nodes
oc debug node/<worker-node> -- chroot /host ovs-vsctl show
```

## Security Considerations

- This network provides direct physical network access - ensure proper network policies
- Consider firewall rules for VLAN 1924 access
- Monitor network traffic for security compliance
- Use network policies to restrict inter-pod communication
- Ensure physical network security for VLAN 1924

## Related Components

- [localnet-1924-dhcp](../localnet-1924-dhcp/) - Same VLAN with DHCP instead of static allocation
- [l2-infra](../l2-infra/) - Layer 2 infrastructure network
- [physnet-mapping](../physnet-mapping/) - Physical network bridge configuration
- [argocd-net-management](../argocd-net-management/) - RBAC for network management

## Network Architecture

```
Physical Network (VLAN 1924)
    ↓
br-vmdata (OVS Bridge)
    ↓
physnet-br-vmdata (Physical Network Mapping)
    ↓
localnet-1924 (CUDN)
    ↓
Pod Network Interfaces
```

This architecture provides a complete bridge from pod network interfaces to the physical VLAN 1924 network, enabling direct connectivity to physical infrastructure.
