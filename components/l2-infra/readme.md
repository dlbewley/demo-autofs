# L2 Infrastructure Network Component

This component defines a Layer 2 (L2) infrastructure network using OpenShift's OVN-Kubernetes ClusterUserDefinedNetwork (CUDN) resource.

## Overview

The `l2-infra` component creates a dedicated Layer 2 network for infrastructure services that require persistent IP addresses and direct L2 connectivity. This network is designed for services that need to maintain consistent network identity and connectivity.

## Network Configuration

### Layer 2 Topology
- **Topology**: Layer2 (direct L2 connectivity)
- **Role**: Secondary (additional network alongside the default cluster network)
- **IPAM**: Enabled with persistent lifecycle
- **Subnet**: `10.168.4.0/24` (254 available IP addresses)
- **Excluded Range**: `10.168.4.0/26` (first 64 IPs reserved)

### Namespace Access
Namespaces can access this network by adding the label:
```yaml
metadata:
  labels:
    l2-overlay: "infra"
```

## Use Cases

This L2 infrastructure network is ideal for:

- **Infrastructure Services**: Monitoring, logging, and management tools
- **Persistent Services**: Applications requiring consistent IP addresses
- **Legacy Integration**: Services that need traditional L2 connectivity
- **Network Isolation**: Infrastructure components separate from application workloads

## IP Address Management

- **Total Addresses**: 254 (10.168.4.1 - 10.168.4.254)
- **Available for Allocation**: 190 (10.168.4.65 - 10.168.4.254)
- **Reserved Range**: 10.168.4.0/26 (10.168.4.0 - 10.168.4.63)
- **Lifecycle**: Persistent (IPs are retained across pod restarts)

## Prerequisites

- OpenShift cluster with OVN-Kubernetes CNI
- Cluster-admin privileges (CUDN creation requires cluster-admin)
- Proper RBAC permissions for ArgoCD to manage CUDN resources

## Usage

### Deploy as Component
```bash
# Include in kustomization.yaml
components:
  - ../../components/l2-infra
```

### Manual Deployment
```bash
oc apply -f components/l2-infra/clusteruserdefinednetwork.yaml
```

### Verify Deployment
```bash
# Check CUDN status
oc get cudn infra

# Check network attachment definitions in namespaces
oc get network-attachment-definitions -A
```

## Network Attachment

Pods can attach to this network by adding the following annotation:

```yaml
apiVersion: v1
kind: Pod
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: infra
spec:
  # pod spec
```

## Troubleshooting

### Common Issues

1. **CUDN Creation Fails**
   - Ensure cluster-admin privileges
   - Verify OVN-Kubernetes is properly configured
   - Check for conflicting network configurations

2. **Pod Network Attachment Fails**
   - Verify namespace has `l2-overlay: "infra"` label
   - Check NetworkAttachmentDefinition exists in namespace
   - Ensure pod has proper security context

3. **IP Allocation Issues**
   - Check available IP range (10.168.4.65 - 10.168.4.254)
   - Verify no IP conflicts with existing allocations
   - Review CUDN status for allocation errors

### Debug Commands

```bash
# Check CUDN detailed status
oc describe cudn infra

# Check network attachment definitions
oc get nad -A

# Check pod network interfaces
oc exec <pod-name> -- ip addr show

# Check OVN logical switches
oc get nodes -o jsonpath='{.items[*].metadata.annotations.k8s\.ovn\.org/node-subnets}'
```

## Security Considerations

- This network provides L2 connectivity - ensure proper network policies
- Consider firewall rules for infrastructure network access
- Monitor network traffic for security compliance
- Use network policies to restrict inter-pod communication

## Related Components

- [localnet-1924](../localnet-1924/) - VLAN-based network with static IP allocation
- [localnet-1924-dhcp](../localnet-1924-dhcp/) - VLAN-based network with DHCP
- [physnet-mapping](../physnet-mapping/) - Physical network bridge configuration
