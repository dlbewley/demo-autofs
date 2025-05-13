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

## Process

To apply a custom layered image to your cluster by using the on-cluster build process, make a MachineOSConfig custom resource (CR) that specifies the following parameters:

the Containerfile to build
the machine config pool to associate the build
where the final image should be pushed and pulled from
the push and pull secrets to use

* One MachineOSConfig resource per machine config pool

### Prerequisites

* [Enable](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/nodes/working-with-clusters#nodes-cluster-enabling) the TechPreviewNoUpgrade feature set by using the feature gates. 

> [!WARNING]
> Enabling the TechPreviewNoUpgrade feature set on your cluster cannot be undone and prevents minor version updates. You should not enable this feature set on production clusters.

```bash
$ oc patch featuregate/cluster --type=json \
  -p='[{"op": "add", "path": "/spec/featureSet", "value": "TechPreviewNoUpgrade"}]'
```

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

* Create a pull-secret for machine-os-builder on the [internal registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/registry/securing-exposing-registry#securing-exposing-registry) (or elsewhere)

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

* Create a pull secret with permission to push to the openshift namespace

```bash
# start with copy of global pull secret
$ OUT=$(mktemp -d)
$ oc extract secret/pull-secret -n openshift-config --to=$OUT

$ export REGISTRY=$(oc get route default-route -n openshift-image-registry \
    --template='{{ .spec.host }}')
$ export REGISTRY_USER=builder
$ export REGISTRY_NAMESPACE=openshift
$ export TOKEN=$(oc create token $REGISTRY_USER -n $REGISTRY_NAMESPACE)
$ podman login --tls-verify=false \
    --compat-auth-file $OUT/.dockerconfigjson \
    -u $REGISTRY_USER \
    -p $TOKEN \
    $REGISTRY
```

* Replace value of `$REGISTRY` with `image-registry.openshift-image-registry.svc` in  $OUT/.dockerconfigjson

```bash
$ vi $OUT/.dockerconfigjson
...
$ jq '.auths | keys' $OUT/.dockerconfigjson
[
  "cloud.openshift.com",
  "image-registry.openshift-image-registry.svc",
  "quay.io",
  "registry.connect.redhat.com",
  "registry.redhat.io"
]
```

* Create "push" secret

```bash
$ oc create secret generic push-secret \
    -n openshift-machine-config-operator \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=$OUT/.dockerconfigjson
$ rm -rf $OUT
```

* Create pull secret

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


* Create [worker-test machineconfigpool](machineconfigpool.yaml) to use for initial testing of the image build.

```bash
oc create -f machineconfigpool.yaml
```

* Update pull and "push" secret names in the [machineosconfig.yaml](machineosconfig.yaml)

```bash
oc create -f machineosconfig.yaml
```

* This will creatae a Job in the openshift-machine-config-operator namespace

* Pod start up takes a couple of minutes. Then watch the logs:

```bash
oc logs build-automount-worker-d0d785ce78be06d4acfc3085854e934b-s5zh5 -n openshift-machine-config-operator -f
```


# ...to be continued