# ClusterUserDefinedNetwork Configuration for Autofs Demonstration


This will deploy to a CUDN of `localnet` topology on VLAN 1924 which will be accessed via the physical network `physnet-br-vmdata` on the worker nodes. These items are referenced via reusable [components](../components/).

* Create an appropriate [overlay](overlays/homelab/kustomization.yaml) for the network.

* Add the appropriate [NodeNetworkConfigurationPolicy](../components/physnet-mapping/nncp.yaml) to the overlay.

* Add the appropriate [ClusterUserDefinedNetwork](../components/localnet-1924-dhcp/clusteruserdefinednetwork.yaml) to the overlay.

* Deploy the networking overlay.

```bash
oc apply -k networking/overlays/homelab
# or
oc apply -k argo-apps/networking
```