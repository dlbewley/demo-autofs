# Deploy VMs using ArgoCD

# Argo Apps

The following ArgoCD applications are defined:

* [demo-autofs App of Apps](demo-autofs/kustomization.yaml) - Deploys all of the following:
  * [demo-autofs-client](client/application.yaml) - Deploys client VM
  * [demo-autofs-ldap](ldap/application.yaml) - Deploys LDAP server VM
  * [demo-autofs-networking](networking/application.yaml) - Sets up required networking configuration
  * [demo-autofs-nfs](nfs/application.yaml) - Deploys NFS server VM

## Cloud-init User Data Hack

> ![NOTE]
> This hacky manual workaround for cloud-init is required due to the currentl lack of secrets management in my lab environment.

Use kustomize to create the namespace and the userData secret as it exists in my working dirctory.

Then create the ArgoCD application pointing at the git repo. The userData secret is annotated to prevent ArgoCD from modifying it with the copy stored in git which allows the Virtual Machine to use the correct userData containing RHEL subscription information.


## Deploying Alls As An App of Apps

```bash
# hacky workaround for cloud init secret management
oc kustomize client/base | kfilt -n cloudinitdisk-client -k namespace | oc apply -f -
oc kustomize ldap/base | kfilt -n cloudinitdisk-ldap -k namespace | oc apply -f -
oc kustomize nfs/base | kfilt -n cloudinitdisk-nfs -k namespace | oc apply -f -

oc apply -k argo-apps/demo-autofs
```

## Deploying Each App Individually
```bash
oc apply -k argo-apps/networking

oc delete -k argo-apps/client
oc delete namespace demo-client
oc kustomize client/base | kfilt -n cloudinitdisk-client -k namespace | oc apply -f -
oc apply -k argo-apps/client

oc delete -k argo-apps/ldap
oc delete namespace demo-ldap
oc kustomize ldap/base | kfilt -n cloudinitdisk-ldap -k namespace | oc apply -f -
oc apply -k argo-apps/ldap

oc delete -k argo-apps/nfs
oc delete namespace demo-nfs
oc kustomize nfs/base | kfilt -n cloudinitdisk-nfs -k namespace | oc apply -f -
oc apply -k argo-apps/nfs
```

## Deployed Applications

![Networking ArgoCD App](../img/argo-app-demo-autofs-network.png)
![LDAP VM ArgoCD App in ACM](../img/acm-app-demo-autofs-ldap.png)
![LDAP VM ArgoCD App](../img/argo-app-demo-autofs-ldap.png)
![NFS VM ArgoCD App](../img/argo-app-demo-autofs-nfs.png)
![CLient VM ArgoCD App](../img/argo-app-demo-autofs-client.png)
