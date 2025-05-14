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
Optionally [expose the registry]](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/registry/securing-exposing-registry#securing-exposing-registry) for testing.

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

* Create or obtain a pull secret with permission to push to image registry in the openshift namespace

* The builder serviceaccount int he openshift namespace has a pull secret enabling push to the internal registry. Copy this secret to openshift-machine-config-operator as `push-secret`.

```bash
oc describe sa builder -n openshift
Name:                builder
Namespace:           openshift
Labels:              <none>
Annotations:         openshift.io/internal-registry-pull-secret-ref: builder-dockercfg-5dsjz
Image pull secrets:  builder-dockercfg-5dsjz
Mountable secrets:   builder-dockercfg-5dsjz
Tokens:              <none>
Events:              <none>

OUT=$(mktemp -d)

oc extract secret/builder-dockercfg-5dsjz -n openshift --to=$OUT
cat $OUT/.dockercfg | jq 'keys'
[
  "172.30.70.87:5000",
  "default-route-openshift-image-registry.apps.agent.lab.bewley.net",
  "image-registry.openshift-image-registry.svc.cluster.local:5000",
  "image-registry.openshift-image-registry.svc:5000"
]

oc create secret generic push-secret \
    -n openshift-machine-config-operator \
    --type=kubernetes.io/dockercfg \
    --from-file=.dockercfg=$OUT/.dockercfg

rm -rf $OUT
```

* Create or obtain a pull secret with permission to pull the base image from Red Hat. Copy this secret to openshift-machine-config-operator as `pull-secret`.

Duplicate the global [pull secret](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/images/managing-images#using-image-pull-secrets) to openshift-machine-config-operator namespace

```bash
$ OUT=$(mktemp -d)
$ oc extract secret/pull-secret -n openshift-config --to=$OUT
# make changes to $OUT/.dockerconfigjson if desired
$ oc create secret generic pull-secret \
    -n openshift-machine-config-operator \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=$OUT/.dockerconfigjson
$ rm -rf $OUT
```

## Build Configs and Layered Image

* Create [worker-test machineconfigpool](machineconfigpool.yaml) to use for initial testing of the image build. Ensure the MCP is initially **paused**.

```bash
oc create -f machineconfigpool.yaml

oc get mcp
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-e8ce721963e267ab05ddb740a9ea87e9             True      False      False      3              3                   3                     0                      8d
worker             rendered-worker-a75414c6dac73af84fc4efc03e2605c2             False     True       True       2              1                   1                     1                      8d
worker-automount   rendered-worker-automount-a75414c6dac73af84fc4efc03e2605c2   True      False      False      0              0                   0                     0                      24s
```

* Create the [machineconfigs](machineconfig.yaml) that configure autofs.

```bash
oc create -f machineconfig.yaml
machineconfig.machineconfiguration.openshift.io/99-worker-automount-sssd-config created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-autofs-service created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-nfs-homedir-setsebool created
```

* Confirm the pull-secret and push-secret references and create the [machineosconfig.yaml](machineosconfig.yaml) which is associated with the just created machineconfig pool.

```bash
oc get secret/pull-secret -n openshift-machine-config-operator
NAME          TYPE                             DATA   AGE
pull-secret   kubernetes.io/dockerconfigjson   1      22h

oc get secret/push-secret -n openshift-machine-config-operator
NAME          TYPE                      DATA   AGE
push-secret   kubernetes.io/dockercfg   1      14m

oc create -f machineosconfig.yaml
```

* When the machineconfig pull is unpaused it will creatae a Job in the openshift-machine-config-operator namespace defined by the machineosconfig

```bash
oc patch machineconfigpool/worker-automount \
    --type merge --patch '{"spec":{"paused":false}}'

oc get jobs -n openshift-machine-config-operator
NAME                                                      STATUS    COMPLETIONS   DURATION   AGE
build-worker-automount-ed7a188f8fcd6d7d6be3c5549299ba47   Running   0/1           2m31s      2m31s
```

* Pod start up takes a couple of minutes. Then watch the logs and confirm a successful push of the resulting image.

```bash
oc logs -n openshift-machine-config-operator -f build-worker-automount-ed7a188f8fcd6d7d6be3c5549299ba47-hcc6r
...
Writing manifest to image destination
+ return 0

oc get machineosconfig,machineosbuild
NAME                                                                 AGE
machineosconfig.machineconfiguration.openshift.io/worker-automount   38m

NAME                                                                                                 PREPARED   BUILDING   SUCCEEDED   INTERRUPTED   FAILED
machineosbuild.machineconfiguration.openshift.io/worker-automount-ed7a188f8fcd6d7d6be3c5549299ba47   False      False      True        False         False
```

## Apply Layered Image to Nodes

Adjust the node-role.kubernetes.io label on the test nodes so they will be configured by the worker-auomount pool which applies the automount configs and the layered image.

```bash
oc label node worker-5 node-role.kubernetes.io/worker- node-role.kubernetes.io/worker-automount=''

oc get mcp
NAME          CONFIG                                                  UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master        rendered-master-6da92f7c2ea89a849a3e8d34ae2df208        True      False      False      3              3                   3                     0                      8d
worker        rendered-worker-fe0c58cc7a2916e33b82d9c62bd30e2b        True      False      False      2              2                   2                     0                      8d
worker-test   rendered-worker-test-fe0c58cc7a2916e33b82d9c62bd30e2b   False     False      False      1              0                   0                     0                      5h40m

oc patch machineconfigpool/worker-test \
    --type merge --patch '{"spec":{"paused":false}}'
```

I'm currently stuck in a degraded state.

https://redhat-internal.slack.com/archives/C02CZNQHGN8/p1747245572935239


# ...to be continued

# References

* https://access.redhat.com/solutions/4970731
* https://access.redhat.com/solutions/5598401

If an MCP update gets hung it may be necessary to login and do the following which should trigger an automatic reboot. SOMETIMES this works. Often not, for me.
```bash
[root@worker-5 ~]# rm /etc/machine-config-daemon/currentconfig
[root@worker-5 ~]# touch /run/machine-config-daemon-force
```