# Using CoreOS Image Layering to run automountd

RHEL CoreOS is a container optimized operating system distributed via a container image. Typically one does not install software directly into the host operating system, but instead runs services via containers.

The [RHCOS Image Layering](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/machine_configuration/mco-coreos-layering) feature of OpenShift allows to the ability to install software at the host level in a manner compatible with the automated node lifecycle management performed by OpenShift.

[internal deck](https://docs.google.com/presentation/d/14rIn35xjR8cptqzYwDoFO6IOWIUNkSBZG3K2-5WJKok/edit?slide=id.g547716335e_0_220#slide=id.g547716335e_0_220)

> [!IMPORTANT]
> On cluster image layering is TP as of 4.18 and anticipated to GA in 4.19.

> [!WARNING]
> Use of image layering will lead to potentially unanticipated reboots when the CA signing cert is rotated and subsequently removed. This occurs at 80% and 100% of the cert lifetime.
> This can be obviated through a coordinated pause of the machineconfig pool.


Note the following limitations when working with the on-cluster layering feature:

* If you scale up a machine set that uses a custom layered image, the nodes reboot two times. The first, when the node is initially created with the base image and a second time when the custom layered image is applied.
* Node disruption policies are not supported on nodes with a custom layered image. As a result the following configuration changes cause a node reboot:
    * Modifying the configuration files in the /var or /etc directory
    * Adding or modifying a systemd service
    * Changing SSH keys
    * Removing mirroring rules from ICSP, ITMS, and IDMS objects
    * Changing the trusted CA, by updating the user-ca-bundle configmap in the openshift-config namespace

## Overview 

To apply a custom layered image to your cluster by using the on-cluster build process, make a MachineOSConfig custom resource (CR) that specifies the following parameters:

the Containerfile to build
the machine config pool to associate the build
where the final image should be pushed and pulled from
the push and pull secrets to use

* One MachineOSConfig resource per machine config pool

## Prerequisites

### Tech Preview Feature Gate

* [Enable](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/nodes/working-with-clusters#nodes-cluster-enabling) the TechPreviewNoUpgrade feature set by using the feature gates. 

> [!WARNING]
> Enabling the TechPreviewNoUpgrade feature set on your cluster cannot be undone and prevents minor version updates. You should not enable this feature set on production clusters.

```bash
$ oc patch featuregate/cluster --type=json \
  -p='[{"op": "add", "path": "/spec/featureSet", "value": "TechPreviewNoUpgrade"}]'
```

### Image Registry to hold layered image

> [!NOTE]
> Using the on-cluster image registry.
> Skip if using an external registry.

* Identify a registry or [enable the on-cluster registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/registry/setting-up-and-configuring-the-registry#configuring-registry-storage-baremetal)

* Create a PVC on non-default SC

```bash
$ cat <<EOF | oc create -f -
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: image-registry-storage-cephfs
  namespace: openshift-image-registry
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Gi
  storageClassName: ocs-storagecluster-cephfs
  volumeMode: Filesystem
EOF
```

* Enable the on cluster registry using above PVC. 
Optionally [expose the registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/registry/securing-exposing-registry#securing-exposing-registry) for testing.

```bash
# Enable registry - if none exists outside cluster
$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"managementState":"Managed"}}'

$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"storage":{"pvc":{"claim":"image-registry-storage-cephfs"}}}}'

# account for pvc
$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"rolloutStrategy":"Recreate"}}'

# Expose registry
$ oc patch configs.imageregistry.operator.openshift.io/cluster \
    --patch '{"spec":{"defaultRoute":true}}' --type=merge
```

### Pull and Push Secrets

Create a pull-secret with the ability to push to the cluster registry in the openshift namespace. Create this as `push-secret`.

* Create a 1 year duration token per this KCS https://access.redhat.com/solutions/7025261 and place that in a pull-secret.

```bash
export REGISTRY=image-registry.openshift-image-registry.svc:5000
export REGISTRY_USER=builder
export REGISTRY_NAMESPACE=openshift
export TOKEN=$(oc create token $REGISTRY_USER -n $REGISTRY_NAMESPACE --duration=$((365*24))h)

oc create secret docker-registry push-secret \
  -n openshift-machine-config-operator \
  --docker-server=$REGISTRY \
  --docker-username=$REGISTRY_USER \
  --docker-password=$TOKEN
```

* Create or obtain a pull secret with permission to pull the base image from Red Hat. Copy this secret to openshift-machine-config-operator as `pull-secret`.

Duplicate the global [pull secret](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/images/managing-images#using-image-pull-secrets) to openshift-machine-config-operator namespace

```bash
OUT=$(mktemp -d)
oc extract secret/pull-secret -n openshift-config --to=$OUT
# make changes to $OUT/.dockerconfigjson if desired
oc create secret generic pull-secret \
  -n openshift-machine-config-operator \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=$OUT/.dockerconfigjson
rm -rf $OUT
```

## Build Configs and Layered Image

* Create [worker-test machineconfigpool](machineconfigpool.yaml) to use for initial testing of the image build. Ensure the MCP is initially **paused**.

```bash
oc create -f machineconfigpool.yaml

oc get mcp
NAME               CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-fe3cb1c0f79e5d3fabf5de4c6b422f2e   True      False      False      3              3                   3                     0                      10d
worker             rendered-worker-8ecca25a0517779ecf6829f69f66501a   True      False      False      2              2                   2                     0                      10d
worker-automount                                                                                                                                                                      4s
```

* Create the [machineconfigs](machineconfig.yaml) that configure autofs.

```bash
oc create -f machineconfig.yaml
machineconfig.machineconfiguration.openshift.io/99-worker-automount-sssd-config created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-autofs-service created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-nfs-homedir-setsebool created
```

* Confirm the pull-secret and push-secrets exist

```bash
oc get secret/pull-secret -n openshift-machine-config-operator
NAME          TYPE                             DATA   AGE
pull-secret   kubernetes.io/dockerconfigjson   1      3m38s

oc get secret/push-secret -n openshift-machine-config-operator
NAME          TYPE                             DATA   AGE
push-secret   kubernetes.io/dockerconfigjson   1      4m14s
```

* Confirm pull secret references in  [machineosconfig.yaml](machineosconfig.yaml) and create it. This machineconfig is associated with the just created `worker-automount` machineconfig pool.

```bash
oc create -f machineosconfig.yaml
machineosconfig.machineconfiguration.openshift.io/worker-automount created
```

* A Job in the openshift-machine-config-operator namespace defined by the machineosconfig will begin a machineosbuild

```
oc get jobs -n openshift-machine-config-operator
NAME                                                      STATUS    COMPLETIONS   DURATION   AGE
build-worker-automount-ac258f40fc636fe53467420d7b557880   Running   0/1           15s        15s

oc get machineosbuild
NAME                                                PREPARED   BUILDING   SUCCEEDED   INTERRUPTED   FAILED
worker-automount-ac258f40fc636fe53467420d7b557880   False      True       False       False         False
```

* Pod start up takes a couple of minutes. Then watch the logs and confirm a successful push of the resulting image.

```bash
oc logs -f build-worker-automount-ac258f40fc636fe53467420d7b557880-l49zq -n openshift-machine-config-operator
...
Writing manifest to image destination
+ return 0

oc get machineosconfig,machineosbuild
NAME                                                                 AGE
machineosconfig.machineconfiguration.openshift.io/worker-automount   38m

NAME                                                                                                 PREPARED   BUILDING   SUCCEEDED   INTERRUPTED   FAILED
machineosbuild.machineconfiguration.openshift.io/worker-automount-ed7a188f8fcd6d7d6be3c5549299ba47   False      False      True        False         False
```

* Successful build:

```
oc get machineosbuild
NAME                                                PREPARED   BUILDING   SUCCEEDED   INTERRUPTED   FAILED
worker-automount-ac258f40fc636fe53467420d7b557880   False      False      True        False         False

oc describe machineosbuild/worker-automount-ac258f40fc636fe53467420d7b557880
Name:         worker-automount-ac258f40fc636fe53467420d7b557880
Namespace:
Labels:       machineconfiguration.openshift.io/machine-os-config=worker-automount
              machineconfiguration.openshift.io/rendered-machine-config=rendered-worker-automount-6312015e2cef0f99c445d816e90af80b
              machineconfiguration.openshift.io/target-machine-config-pool=worker-automount
Annotations:  <none>
API Version:  machineconfiguration.openshift.io/v1alpha1
Kind:         MachineOSBuild
Metadata:
  Creation Timestamp:  2025-05-15T18:32:15Z
  Generation:          1
  Resource Version:    11381424
  UID:                 655afad6-0c33-46fc-b98c-4f11f8bcab8f
Spec:
  Config Generation:  1
  Desired Config:
    Name:  rendered-worker-automount-6312015e2cef0f99c445d816e90af80b
  Machine OS Config:
    Name:                   worker-automount
  Rendered Image Pushspec:  image-registry.openshift-image-registry.svc:5000/openshift/os-image:worker-automount-ac258f40fc636fe53467420d7b557880
  Version:                  1
Status:
  Build End:    2025-05-15T18:43:46Z
  Build Start:  2025-05-15T18:32:26Z
  Builder Reference:
    Build Pod:
      Group:
      Name:              build-worker-automount-ac258f40fc636fe53467420d7b557880
      Namespace:         openshift-machine-config-operator
      Resource:          11381343
    Image Builder Type:  PodImageBuilder
  Conditions:
    Last Transition Time:  2025-05-15T18:32:26Z
    Message:               Build Prepared and Pending
    Reason:                Prepared
    Status:                False
    Type:                  Prepared
    Last Transition Time:  2025-05-15T18:32:26Z
    Message:               Build Failed
    Reason:                Failed
    Status:                False
    Type:                  Failed
    Last Transition Time:  2025-05-15T18:32:26Z
    Message:               Build Interrupted
    Reason:                Interrupted
    Status:                False
    Type:                  Interrupted
    Last Transition Time:  2025-05-15T18:43:46Z
    Message:               Image Build In Progress
    Reason:                Building
    Status:                False
    Type:                  Building
    Last Transition Time:  2025-05-15T18:43:46Z
    Message:               Build Ready
    Reason:                Ready
    Status:                True
    Type:                  Succeeded
  Final Image Pullspec:    image-registry.openshift-image-registry.svc:5000/openshift/os-image@sha256:0b9ca241da2f41c03d2106c24ce9dee2370329771d7883508ddfc1d4712fc310
Events:                    <none>
```

## Apply Layered Image to Nodes

Save node annotations for debugging [worker-5/annotations-at-node-build.yaml](worker-5/annotations-at-node-build.yaml)

```bash
oc get node worker-5 -o yaml | yq '.metadata.annotations' > worker-5/annotations-at-node-build.yaml
```


```
oc get mcp
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-fe3cb1c0f79e5d3fabf5de4c6b422f2e             True      False      False      3              3                   3                     0                      10d
worker             rendered-worker-8ecca25a0517779ecf6829f69f66501a             True      False      False      2              2                   2                     0                      10d
worker-automount   rendered-worker-automount-6312015e2cef0f99c445d816e90af80b   True      False      False      0              0                   0                     0                      18m
```

* Adjust the node-role.kubernetes.io label on the test nodes so they will be configured by the worker-auomount pool which applies the automount configs and the layered image.

```bash
oc label node worker-5 node-role.kubernetes.io/worker- node-role.kubernetes.io/worker-automount=''

oc get mcp
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-fe3cb1c0f79e5d3fabf5de4c6b422f2e             True      False      False      3              3                   3                     0                      10d
worker             rendered-worker-8ecca25a0517779ecf6829f69f66501a             True      False      False      1              1                   1                     0                      10d
worker-automount   rendered-worker-automount-6312015e2cef0f99c445d816e90af80b   False     False      False      1              0                   0                     0                      20m
```

* Notice there is 1 mahcine in the worker-automount MCP. Un pause the MCP

```bash
oc patch machineconfigpool/worker-automount \
    --type merge --patch '{"spec":{"paused":false}}'
```
* Begin watching the MCD logs in another terminal

```bash
oc get pods -n openshift-machine-config-operator -o wide | grep worker-5
kube-rbac-proxy-crio-worker-5                1/1     Running   5 (24m ago)   23m   192.168.4.205   worker-5   <none>           <none>
machine-config-daemon-ht2wx                  2/2     Running   0             15m   192.168.4.205   worker-5   <none>           <none>
machine-os-builder-58547b4fb9-fzcrr          1/1     Running   0             16m   10.129.2.12     worker-5   <none>           <none>

oc logs -n openshift-machine-config-operator machine-config-daemon-ht2wx -f
```

> [!IMPORTANT]
> **FAILED**
>
> * Log is in [worker-5/mcd.log](worker-5/mcd.log)
> * Annotations in [worker-5/annotations-after-mcp-change.yaml](worker-5/annotations-after-mcp-change.yaml)
>
> E0515 18:56:46.084164   14695 writer.go:226] Marking Degraded due to: "failed to update OS to image-registry.openshift-image-registry.svc:5000/openshift/os-image@sha256:0b9ca241da2f41c03d2106c24ce9dee2370329771d7883508ddfc1d4712fc310: error running rpm-ostree rebase --experimental ostree-unverified-registry:image-registry.openshift-image-registry.svc:5000/openshift/os-image@sha256:0b9ca241da2f41c03d2106c24ce9dee2370329771d7883508ddfc1d4712fc310: error: Old and new refs are equal: ostree-unverified-registry:image-registry.openshift-image-registry.svc:5000/openshift/os-image@sha256:0b9ca241da2f41c03d2106c24ce9dee2370329771d7883508ddfc1d4712fc310\n: exit status 1"


```bash
oc get nodes
ocNAME       STATUS                        ROLES                         AGE    VERSION
master-1   Ready                         control-plane,master,worker   10d    v1.31.7
master-2   Ready                         control-plane,master,worker   10d    v1.31.7
master-3   Ready                         control-plane,master,worker   10d    v1.31.7
worker-4   Ready                         worker                        10d    v1.31.7
worker-5   NotReady,SchedulingDisabled   worker-automount              169m   v1.31.7

oc get mcp
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-fe3cb1c0f79e5d3fabf5de4c6b422f2e             True      False      False      3              3                   3                     0                      10d
worker             rendered-worker-8ecca25a0517779ecf6829f69f66501a             True      False      False      1              1                   1                     0                      10d
worker-automount   rendered-worker-automount-6312015e2cef0f99c445d816e90af80b   False     True       True       1              0                   0                     1                      164m
```

# References

* https://access.redhat.com/solutions/4970731
* https://access.redhat.com/solutions/5598401
* https://redhat-internal.slack.com/archives/C02CZNQHGN8/p1747245572935239
