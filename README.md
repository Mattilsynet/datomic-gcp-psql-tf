# Datomic on GCP

A Terraform module, a Docker image, and an Ansible collection to run a Datomic
transactor on Google Cloud Platform (GCP) with a local Postgres storage backend.

## Overview

The Terraform module installs the following resources (see [main.tf](./main.tf)
for details:

- A virtual private network (VPC) with a single subnet
- A VPC access connector for Google serverless components (e.g. to be able to
  connect from CloudRun)
- A service account with the following roles:
  - [`roles/cloudsql.client`](https://cloud.google.com/sql/docs/mysql/iam-roles)
  - [`roles/secretmanager.secretAccessor`](https://cloud.google.com/secret-manager/docs/access-control)
  - [`roles/secretmanager.viewer`](https://cloud.google.com/secret-manager/docs/access-control)
  - [`roles/compute.viewer`](https://cloud.google.com/compute/docs/access/iam)
- A Compute Engine VM
- An [IAP tunnel accessor](https://cloud.google.com/iap/docs/concepts-overview)
  for GCP authorized SSH access.
- A NAT for outbound traffic from the VM
- Secrets holding the Postgres user name and password

The Ansible collection prepares the VM for running the Datomic transactor as a
Docker container on ports 4337, 4338 and 4339. These ports were deliberately
selected to not overlap with the default ports, as this allows you to seemlessly
connect to production even when running a local transactor.

## How to use

To spin up the transactor you will perform three steps:

1. Configure and run the Terraform module
2. Build and publish the Docker image
3. Configure and run the Ansible collection

### Running the Terraform module

Create your own Terraform project with a `settings.yml` file:

```sh
mkdir datomic-gcp-psql
cd datomic-gcp-psql
touch settings.yml
```

Configure Terraform to your liking. The state backend is up to you, but you must
include the google providers config:

```yml
# settings.yml

terraform {
  required_version = ">= 1.1.7"
  backend "gcs" {
    bucket = "my-state-bucket"
    prefix = "datomic"
  }
}

provider "google" {
  region = "europe-north1"
  impersonate_service_account = "my-sa@my-project.iam.gserviceaccount.com"
}

provider "google-beta" {
  region = "europe-north1"
  impersonate_service_account = "my-sa@my-project.iam.gserviceaccount.com"
}
```

Next, create a `main.yml` file and configure the terraform module:

```yml
locals {
  project_id = "myproject-1111"
  region = "europe-north1"
}

module "datomic" {
  source = "github.com/Mattilsynet/datomic-gcp-psql-tf.git//datomic-vm"
  project_id = local.project_id
  region = local.region
  name = "datomic"
  iap_access_members = [
    "group:my-team@my-corp.com"
  ]
  depends_on = [google_project_service.vpcaccess]
}
```

`iap_access_members` is a list of users or groups of users who should be allowed
to use the IAP SSH tunnel into the VM. `name` is used to prefix some names that
need to be unique within the managed environment.

Now run `terraform init` followed by `terraform apply`. This will take a while.

### Building and publishing the Datomic image

Clone this repo. You will need a Docker repository to push the image to. Follow
the official documentation to [create a GCP Docker
repository](https://cloud.google.com/build/docs/build-push-docker-image).

Then build, tag and push the image:

```sh
cd docker

gcloud auth configure-docker europe-north1-docker.pkg.dev
IMAGE=europe-north1-docker.pkg.dev/my-project-000/myrepo/datomic make publish
```

This will tag the image with both the current git commit sha and `latest`.

If you need a Docker repository to push to, you can use GCP artifact registry:

```sh
locals {
  project_id = "myproject-1111"
  region = "europe-north1"
}

# ...

resource "google_artifact_registry_repository" "repo" {
  project = local.project_id
  location = local.region
  repository_id = "datomic-transactor"
  format = "DOCKER"
}

resource "google_artifact_registry_repository_iam_member" "artifact_registry_reader" {
  project = local.project_id
  location = local.region
  member = "serviceAccount:${module.datomic.service_account_email}"
  repository = "datomic-transactor"
  role = "roles/artifactregistry.reader"
}
```

### Running the Ansible collection

Clone this repo, and make a copy of the inventory template:

```sh
cp ansible/inventory/datomic.gcp.yaml.sample \
  ansible/inventory/datomic.gcp.yaml
```

Edit `ansible/inventory/datomic.gcp.yaml` and enter your specific project id,
region, Docker image, and VM instance name. The `instance_name` should be set to
the same value you used for `name` in the Terraform module.

The Ansible collection will use `gcloud` and run `jq` as local commands, so make
sure you have both installed on your machine, and that you have run `gcloud auth
login` and `gcloud auth application-default login` before running Ansible.

- [Install Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html)
- [Install gcloud tooling](https://duckduckgo.com/?q=install+gcloud&ia=web)
- [Install jq](https://jqlang.github.io/jq/download/)

Now SSH into the server once to make sure that the GCP tooling installs an SSH
certificate on your machine and on the remote server, and to verify that things
are set up correctly:

```sh
gcloud compute ssh \
  --zone europe-north1-a \
  --tunnel-through-iap \
  --project myproject-111 \
  datomic-vm
```

Then run the Ansible collection:

```sh
cd ansible
ansible-playbook -i inventory/datomic.gcp.yaml playbooks/setup-datomic.yml
```

## Connecting to the transactor

To connect to the transactor, you need the Postgres user name and password. The
Terraform module stores these as secrets:

```sh
pwd=$(gcloud secrets versions access latest --secret "datomic-postgres-password")
user=$(gcloud secrets versions access latest --secret "datomic-postgres-user")
```

Then use a connection string like:

```clj
"datomic:sql://datomic-db-name?jdbc:postgresql:///datomic?user=datomic-user&password=..."
```

## Local access to production

When a Datomic peer establishes a connection, it will go to the storage to find
the location of the transactor. The transactor will give its location as
`10.0.0.2`, thus we need for that IP to resolve from our local machine in
order to reach it. You can add it as an alias on your en0 interface:

```sh
sudo ifconfig en0 alias 10.0.0.2 netmask 255.255.255.0
```

Next, run an SSH tunnel to the Datomic VM on this IP:

```sh
gcloud compute start-iap-tunnel \
  --local-host-port 10.0.0.2:4337 \
  --zone europe-north1-a \
  --project project-id \
  datomic-vm 4337
```

In another terminal, run an SSH tunnel to the VM on the Postgres IP:

```sh
gcloud compute start-iap-tunnel \
  --local-host-port 10.0.0.2:5432 \
  --zone europe-north1-a \
  --project project-id \
  datomic-vm 5432
```

Adjust project id and zone as appropriate. With the two proxies established, you
should now be able to connect to the transactor with the following connection
string:

```clj
"datomic:sql://datomic-db-name?jdbc:postgresql:///datomic?user=datomic-user&password=..."
```
