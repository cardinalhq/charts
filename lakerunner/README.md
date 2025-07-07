# Lakerunner

## Requirements

* A Kubernetes cluster running a modern version of Kubernetes, at least 1.28.
* A PostgreSQL database, at least version 16.
* An S3 (or compatible) object store configured to send object create notifications.

For AWS S3, SQS queues are used (which the helm chart assumes).  Other systems may have
other mechanisms, and a webhook-style receiver can be enabled to support them.

## Installation

Create a `values-local.yaml` file (see below) and run:

```sh
helm install lakerunner oci://public.ecs.aws/cardinalhq.io/lakerunner \
   --version 0.2.10 \
   --values values-local.yaml \
   --namespace lakerunner --create-namespace
```

## `value-local.yaml`

The [default `values.yaml`](https://github.com/cardinalhq/charts/blob/main/lakerunner/values.yaml) file has several settings you will need to provide.

* AWS credentials, which are required to be in a secret (for now), either in the values file or an existing secret name to get them from.
* PostgreSQL connection details
* PostgreSQL password, or a secret to get it from.
* Storage Profiles
* API Keys
* Inter-process token
* If using a non-AWS S3, select the webhook-style pubsub receiver and disable the SQS one.

Items you may want to change, but are not required:

* Scaling setup.
* Memory and CPU limits.

The settings in the values.yaml file are suitable for a small to medium installation,
but for a very small or larger installation, you will need to make adjustments.

## Secrets

Secrets are used for all credentials.  They can be provided in the values files (not recommended) or
created and their names provided in the values file.  If the secret names are provided, the name of
the secret is the name provided in values, and if it is not provided (`create` is set to `true` for that
secret) it will be prefixed with the release name.

## Storage Profiles

Storage Profiles are used to map from an incoming bucket notification to the organization
and collector instance.  Even if you only have a single bucket, one collector, and one
organization, you need to define a profile.

Storage profiles are defined in YAML, via the values file:

```yaml
storageProfiles:
  yaml: []
    - organization_id: dddddddd-aaaa-4ff9-ae8f-365873c552f0
      instance_num: 1
      collector_name: "kubepi"
      cloud_provider: "aws"
      region: "us-east-2"
      bucket: "datalake-11ndajkhk"
      use_path_style: true
```

The organization_id is arbitrary, but must be a UUID.
`instance_num` should be unique within the same organization, and will need to be different per collector name.
`collector_name` is used as part of the path prefix, and needs to be set to the name of the CardinalHQ collector.
`use_path_style` should be `true`.
The other fields are generally obvious.

If you are using a non-AWS S3 provider, there is also an `endpoint` option to list the URL for your S3
endpoint.

## API Keys

API Keys are used to provide access to the data stored in your data lake.  These
are used by the `query-api` and `query-worker` to authenticate and authorize
access to the organiation's data stored in the lake.

These are defined in YAML, via the values file:

```yaml
apiKeys:
  secretName: "apikeys" # will have the format <release-name>-apikeys once deployed
  create: true
  yaml: []
    - organization_id: dddddddd-aaaa-4ff9-ae8f-365873c552f0
      keys:
        - my-api-key-1
        - my-api-key-2
```

The `organization_id` should match ones used in the storage profile.

Multiple keys can be used.  If the Lakerunner query API is not used, these can be left blank.
